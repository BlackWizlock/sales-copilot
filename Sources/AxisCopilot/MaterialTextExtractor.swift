import Foundation
import PDFKit
import Vision
import ImageIO
import CoreGraphics

/// Reads reference material on this Mac only. Call from a background task.
enum MaterialTextExtractor {
    static let supportedExtensions = ["pdf", "txt", "md", "csv", "tsv", "json", "docx", "doc", "rtf", "html", "htm", "pptx", "xlsx", "png", "jpg", "jpeg", "tif", "tiff", "heic"]
    private static let maximumText = 60_000
    private static let maximumBytes = 20 * 1_024 * 1_024

    enum ExtractionError: LocalizedError {
        case invalidFile, tooLarge, unsupported(String), unreadable, empty, textTooLong, timeout, archiveTooLarge
        var errorDescription: String? {
            switch self {
            case .invalidFile: return L10n.string("Выберите обычный локальный файл, а не папку или символическую ссылку.")
            case .tooLarge: return L10n.string("Материал больше 20 МБ. Разделите его на несколько файлов.")
            case .unsupported(let type): return L10n.format("Формат .%@ пока не поддерживается. Сохраните материал как PDF или текст.", String(describing: type))
            case .unreadable: return L10n.string("Не удалось прочитать материал. Возможно, он повреждён или защищён паролем.")
            case .empty: return L10n.string("В материале не найден текст.")
            case .textTooLong: return L10n.string("Материал содержит больше 60 000 символов. Разделите его на части.")
            case .timeout: return L10n.string("Обработка материала заняла слишком много времени. Разделите его на части.")
            case .archiveTooLarge: return L10n.string("Внутреннее содержимое документа слишком велико для безопасной обработки.")
            }
        }
    }

    static func extract(url: URL) throws -> String {
        guard url.isFileURL else { throw ExtractionError.invalidFile }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Reject links in any component, including a linked parent directory.
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw ExtractionError.invalidFile
        }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw ExtractionError.invalidFile }
        guard (info.fileSize ?? maximumBytes + 1) <= maximumBytes else { throw ExtractionError.tooLarge }
        let type = url.pathExtension.lowercased()
        guard supportedExtensions.contains(type) else { throw ExtractionError.unsupported(type) }
        let deadline = Date().addingTimeInterval(90)
        let result: String
        switch type {
        case "pdf": result = try pdf(url, deadline: deadline)
        case "docx", "pptx", "xlsx": result = try office(url, type: type, deadline: deadline)
        case "doc", "rtf":
            result = try decode(run("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path], limit: 1_024 * 1_024))
        case "html", "htm": result = html(try decode(read(url)))
        case "png", "jpg", "jpeg", "tif", "tiff", "heic": result = try imageText(url, deadline: deadline)
        default: result = try decode(read(url))
        }
        return try checked(result)
    }

    private static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ExtractionError.tooLarge }
        return data
    }

    private static func checked(_ text: String) throws -> String {
        let text = text.replacingOccurrences(of: "\u{0000}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExtractionError.empty }
        guard text.count <= maximumText else { throw ExtractionError.textTooLong }
        return text
    }

    private static func decode(_ data: Data) throws -> String {
        // A UTF-16 BOM must be checked before legacy encodings.
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]), let value = String(data: data, encoding: .utf16) { return value }
        for encoding in [String.Encoding.utf8, .windowsCP1251, .windowsCP1252] {
            if let value = String(data: data, encoding: encoding) { return value }
        }
        throw ExtractionError.unreadable
    }

    private static func pdf(_ url: URL, deadline: Date) throws -> String {
        guard let document = PDFDocument(url: url), !document.isLocked else { throw ExtractionError.unreadable }
        guard document.pageCount <= 200 else { throw ExtractionError.tooLarge }
        var chunks: [String] = []
        var count = 0
        for index in 0..<document.pageCount {
            guard Date() < deadline else { throw ExtractionError.timeout }
            guard let page = document.page(at: index) else { continue }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let bounds = page.bounds(for: .mediaBox)
                guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { continue }
                let scale = min(2_000 / bounds.width, 2_000 / bounds.height)
                let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExtractionError.unreadable }
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -bounds.minX, y: -bounds.minY)
                page.draw(with: .mediaBox, to: context)
                if let image = context.makeImage() { text = try recognize(image) }
            }
            count += text.count + 1
            guard count <= maximumText else { throw ExtractionError.textTooLong }
            chunks.append(text)
        }
        return chunks.joined(separator: "\n")
    }

    private static func imageText(_ url: URL, deadline: Date) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ExtractionError.unreadable }
        guard CGImageSourceGetCount(source) <= 20 else { throw ExtractionError.tooLarge }
        var chunks: [String] = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard Date() < deadline else { throw ExtractionError.timeout }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2_000, kCGImageSourceCreateThumbnailWithTransform: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { throw ExtractionError.unreadable }
            chunks.append(try recognize(image))
            if chunks.reduce(0, { $0 + $1.count }) > maximumText { throw ExtractionError.textTooLong }
        }
        return chunks.joined(separator: "\n")
    }

    private static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        request.usesLanguageCorrection = true
        let box = OCRResultBox()
        let completion = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<String, Error> {
                try VNImageRequestHandler(cgImage: image).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }
            box.lock.lock(); box.result = result; box.lock.unlock()
            completion.signal()
        }
        guard completion.wait(timeout: .now() + 20) == .success else {
            request.cancel()
            throw ExtractionError.timeout
        }
        box.lock.lock(); defer { box.lock.unlock() }
        guard let result = box.result else { throw ExtractionError.unreadable }
        return try result.get()
    }

    private final class OCRResultBox: @unchecked Sendable {
        let lock = NSLock()
        var result: Result<String, Error>?
    }

    /// No archive files are written to disk. Every subprocess has bounded output and runtime.
    private static func office(_ url: URL, type: String, deadline: Date) throws -> String {
        let listing = try decode(run("/usr/bin/unzip", ["-Z1", url.path], limit: 1_024 * 1_024))
        let names = listing.components(separatedBy: .newlines)
        let pattern: String
        switch type {
        case "docx": pattern = "^word/(document|header[0-9]+|footer[0-9]+|footnotes|endnotes)\\.xml$"
        case "pptx": pattern = "^ppt/(slides/slide[0-9]+|notesSlides/notesSlide[0-9]+)\\.xml$"
        default: pattern = "^xl/(sharedStrings|worksheets/sheet[0-9]+)\\.xml$"
        }
        let entries = names.filter { $0.range(of: pattern, options: .regularExpression) != nil }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !entries.isEmpty else { throw ExtractionError.unreadable }
        guard entries.count <= 500 else { throw ExtractionError.archiveTooLarge }
        var total = 0
        var sharedStrings: [String] = []
        var chunks: [String] = []
        for entry in entries {
            guard Date() < deadline else { throw ExtractionError.timeout }
            let data = try run("/usr/bin/unzip", ["-p", url.path, entry], limit: 4 * 1_024 * 1_024)
            total += data.count
            guard total <= 12 * 1_024 * 1_024 else { throw ExtractionError.archiveTooLarge }
            let reader = OfficeXMLReader(sharedStrings: sharedStrings, sheet: type == "xlsx" && entry.contains("worksheets/"))
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = reader
            guard parser.parse(), !reader.tooLong else { throw reader.tooLong ? ExtractionError.textTooLong : ExtractionError.unreadable }
            if entry == "xl/sharedStrings.xml" { sharedStrings = reader.sharedItems }
            else { chunks.append(reader.output) }
            if chunks.reduce(0, { $0 + $1.count }) > maximumText { throw ExtractionError.textTooLong }
        }
        return chunks.joined(separator: "\n")
    }

    private static func html(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)<[^>]+>", with: "\n", options: .regularExpression)
        for (entity, decoded) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] { value = value.replacingOccurrences(of: entity, with: decoded) }
        return value
    }

    private static func run(_ executable: String, _ arguments: [String], limit: Int) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
        defer { deadline.cancel(); try? pipe.fileHandleForReading.close() }
        var output = Data()
        while true {
            let chunk = pipe.fileHandleForReading.readData(ofLength: 16_384)
            if chunk.isEmpty { break }
            guard output.count + chunk.count <= limit else {
                process.terminate()
                process.waitUntilExit()
                throw ExtractionError.archiveTooLarge
            }
            output.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExtractionError.unreadable }
        return output
    }

    private final class OfficeXMLReader: NSObject, XMLParserDelegate {
        var output = ""
        var sharedItems: [String] = []
        var tooLong = false
        private let sharedStrings: [String]
        private let sheet: Bool
        private var capture = false
        private var buffer = ""
        private var item = ""
        private var cellType = ""
        init(sharedStrings: [String], sheet: Bool) { self.sharedStrings = sharedStrings; self.sheet = sheet }
        private func local(_ name: String) -> String { name.components(separatedBy: ":").last ?? name }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let name = local(elementName)
            if name == "c" { cellType = attributeDict["t"] ?? "" }
            if name == "si" { item = "" }
            if name == "t" || (sheet && name == "v") { capture = true; buffer = "" }
            if name == "tab" { output += "\t" }
            if name == "br" { output += "\n" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capture { buffer += string }
            if buffer.count + output.count > 60_000 { tooLong = true; parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = local(elementName)
            if name == "t" || (sheet && name == "v") {
                if sheet && name == "v" && cellType == "s" {
                    if let index = Int(buffer), sharedStrings.indices.contains(index) { output += sharedStrings[index] }
                } else { output += buffer }
                item += buffer
                capture = false
            }
            if name == "si" { sharedItems.append(item) }
            if ["p", "row", "si"].contains(name) { output += "\n" }
            if sheet && name == "c" { output += "\t" }
            if output.count > 60_000 { tooLong = true; parser.abortParsing() }
        }
    }
}
