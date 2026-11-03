import AppKit
import Foundation

// Reproducible vector artwork rendered at each native macOS icon resolution.
guard CommandLine.arguments.count == 2 else { fatalError("Pass the repository root") }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let teal = NSColor(srgbRed: 36 / 255, green: 145 / 255, blue: 155 / 255, alpha: 1)
let darkTeal = NSColor(srgbRed: 27 / 255, green: 110 / 255, blue: 123 / 255, alpha: 1)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Icon bitmap unavailable") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        context.shouldAntialias = true
        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
        NSGradient(starting: darkTeal, ending: teal)!.draw(in: tile, angle: 90)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 222, y: 318, width: 580, height: 416), xRadius: 100, yRadius: 100).fill()
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 298, y: 342))
        tail.line(to: NSPoint(x: 298, y: 242))
        tail.curve(to: NSPoint(x: 428, y: 342), controlPoint1: NSPoint(x: 344, y: 258), controlPoint2: NSPoint(x: 388, y: 302))
        tail.close(); tail.fill()
        teal.setFill()
        for (index, height) in [80.0, 156, 248, 156, 80].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 334 + Double(index) * 78, y: 526 - height / 2, width: 44, height: height), xRadius: 22, yRadius: 22).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"), options: .atomic)
        if pixels == 1024 { try png.write(to: root.appendingPathComponent("Resources/AppIcon.png"), options: .atomic) }
    }
}
let converter = Process()
converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
converter.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try converter.run(); converter.waitUntilExit()
guard converter.terminationStatus == 0 else { fatalError("ICNS conversion failed") }
print("PASS: AppIcon.icns with 16–1024 pixel representations")
