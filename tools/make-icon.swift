// Draws BTranslate's icon and writes Resources/AppIcon.icns.
//   swift tools/make-icon.swift        (from the repository's top folder)
import Cocoa

func draw(_ pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024  // everything below is laid out on a 1024-point canvas
    let transform = NSAffineTransform()
    transform.scale(by: s)
    transform.concat()

    // The rounded square of a macOS icon: 824 points wide, centred.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(calibratedRed: 0.20, green: 0.36, blue: 0.95, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.56, blue: 1.00, alpha: 1),
                        NSColor(calibratedRed: 0.24, green: 0.27, blue: 0.86, alpha: 1)])!.draw(in: tile, angle: -90)

    func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
    func put(_ text: String, font: NSFont, color: NSColor, centre: NSPoint) {
        let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = str.size()
        str.draw(at: NSPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2))
    }

    // A big white B, and a white card with the character 文 ("writing") overlapping its corner.
    put("B", font: rounded(560, .heavy), color: .white, centre: NSPoint(x: 420, y: 560))
    let card = NSBezierPath(roundedRect: NSRect(x: 520, y: 190, width: 320, height: 320), xRadius: 78, yRadius: 78)
    NSGraphicsContext.saveGraphicsState()
    let cardShadow = NSShadow()
    cardShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    cardShadow.shadowOffset = NSSize(width: 0, height: -6 * s)
    cardShadow.shadowBlurRadius = 18 * s
    cardShadow.set()
    NSColor.white.setFill()
    card.fill()
    NSGraphicsContext.restoreGraphicsState()
    put("文", font: NSFont.systemFont(ofSize: 220, weight: .bold),
        color: NSColor(calibratedRed: 0.24, green: 0.30, blue: 0.88, alpha: 1), centre: NSPoint(x: 680, y: 350))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("BTranslate-\(ProcessInfo.processInfo.processIdentifier).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    let png = draw(points * scale).representation(using: .png, properties: [:])!
    try png.write(to: iconset.appendingPathComponent(name))
}
if CommandLine.arguments.count > 1 {  // a preview PNG, to look at the design
    try draw(512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
