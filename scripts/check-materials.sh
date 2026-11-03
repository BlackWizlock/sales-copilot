#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
python3 - "$ROOT" <<'PY_CHECK'
from pathlib import Path
import os, subprocess, sys, tempfile, zipfile
root=Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="axis-material-check-") as temporary:
 p=Path(temporary).resolve()
 def write(name,data): (p/('material-check'+name)).write_text(data)
 def archive(ext,entries):
  with zipfile.ZipFile(p/('material-check'+ext),'w',zipfile.ZIP_DEFLATED) as z:
   for name,data in entries.items(): z.writestr(name,data)
 archive('.docx',{'word/document.xml':'<w:document xmlns:w="w"><w:p><w:r><w:t>Документ проверка</w:t></w:r></w:p></w:document>'})
 archive('.pptx',{f'ppt/slides/slide{i}.xml':f'<a:p xmlns:a="a"><a:r><a:t>Слайд {i}</a:t></a:r></a:p>' for i in [10,2,1]})
 archive('.xlsx',{'xl/sharedStrings.xml':'<sst><si><t>Материал</t></si></sst>','xl/worksheets/sheet1.xml':'<worksheet><row><c t="s"><v>0</v></c><c><v>42</v></c><c t="inlineStr"><is><t>Встроенный</t></is></c></row></worksheet>'})
 write('.txt','Локальный текст')
 write('.html','<html><script>secret</script><style>secret</style><body>Проверка &amp; HTML</body></html>')
 write('.rtf',r'{\rtf1\ansi Hello RTF}')
 write('-empty.txt','  ')
 write('-long.txt','x'*60001)
 write('-big.txt','x'*(20*1024*1024+1))
 write('.exe','unsupported')
 write('-corrupt.docx','not zip')
 archive('-bomb.docx',{'word/document.xml':'<document>'+('x'*5000000)+'</document>'})
 (p/'material-check-link.txt').symlink_to(p/'material-check.txt')
 (p/'material-check-dir.txt').mkdir()
 harness = r'''import Foundation
import AppKit
import PDFKit

@main struct ExtractionChecks {
    static func main() throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1])
        func expect(_ file: String, _ words: [String]) throws {
            let text = try MaterialTextExtractor.extract(url: base.appendingPathComponent(file))
            for word in words { precondition(text.contains(word), "Missing \(word) in \(file): \(text)") }
            print("PASS \(file)")
        }
        func reject(_ file: String) {
            do { _ = try MaterialTextExtractor.extract(url: base.appendingPathComponent(file)); fatalError("Accepted \(file)") }
            catch { print("PASS rejected \(file): \(error.localizedDescription)") }
        }
        try expect("material-check.docx", ["Документ", "проверка"])
        try expect("material-check.pptx", ["Слайд 1", "Слайд 2", "Слайд 10"])
        try expect("material-check.xlsx", ["Материал", "42", "Встроенный"])
        try expect("material-check.txt", ["Локальный текст"])
        try expect("material-check.html", ["Проверка", "&", "HTML"])
        let htmlText = try MaterialTextExtractor.extract(url: base.appendingPathComponent("material-check.html"))
        precondition(!htmlText.contains("secret"))
        try expect("material-check.rtf", ["Hello RTF"])
        reject("material-check-empty.txt")
        reject("material-check-long.txt")
        reject("material-check-big.txt")
        reject("material-check-link.txt")
        reject("material-check.exe")
        reject("material-check-corrupt.docx")
        reject("material-check-bomb.docx")
        reject("material-check-dir.txt")
        if ProcessInfo.processInfo.environment["CHECK_OCR"] == "1" {
        let image = NSImage(size: NSSize(width: 1200, height: 300))
        image.lockFocus()
        NSColor.white.setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1200, height: 300)).fill()
        ("LOCAL MATERIAL 42" as NSString).draw(at: NSPoint(x: 50, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let imageURL = base.appendingPathComponent("material-check.png")
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: imageURL)
        try expect("material-check.png", ["LOCAL", "42"])
        let pdf = PDFDocument(); pdf.insert(PDFPage(image: image)!, at: 0)
        precondition(pdf.write(to: base.appendingPathComponent("material-check-scan.pdf")))
        try expect("material-check-scan.pdf", ["LOCAL", "42"])
        }
        print("ALL EXTRACTION CHECKS PASSED")
    }
}
'''
 (p/'checks.swift').write_text(harness)
 subprocess.run(['xcrun','swiftc',str(root/'Sources/AxisCopilot/Localization.swift'),str(root/'Sources/AxisCopilot/MaterialTextExtractor.swift'),str(p/'checks.swift'),'-o',str(p/'checks')],check=True,timeout=60)
 subprocess.run([str(p/'checks'),str(p)],check=True,timeout=90)
PY_CHECK
