// Draws the JH Mirror icon: a phone showing "JH" with its mirrored reflection.
// Usage: swift make_icon.swift <project folder>   → AppIcon.iconset, Android app icon, packaging/AppIcon64.png
import AppKit
import Foundation

func drawIcon(in context: CGContext, pixels: Int) {
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    // Tile
    let tile = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 204, yRadius: 204)
    NSGradient(colors: [NSColor(calibratedRed: 0.47, green: 0.25, blue: 0.96, alpha: 1),
                        NSColor(calibratedRed: 0.15, green: 0.39, blue: 0.94, alpha: 1),
                        NSColor(calibratedRed: 0.05, green: 0.65, blue: 0.91, alpha: 1)])!.draw(in: tile, angle: -60)
    tile.setClip()
    // Soft light from the top
    NSGradient(starting: NSColor.white.withAlphaComponent(0.18), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: 60, y: 560, width: 904, height: 404), angle: -90)

    let phone = NSRect(x: 342, y: 330, width: 340, height: 560)
    // Reflection (the "mirror"): the phone flipped below, fading out
    NSGraphicsContext.saveGraphicsState()
    let reflection = NSBezierPath(rect: NSRect(x: 60, y: 60, width: 904, height: 270))
    reflection.setClip()
    let flip = NSAffineTransform()
    flip.translateX(by: 0, yBy: 2 * phone.minY - 18)
    flip.scaleX(by: 1, yBy: -1)
    flip.concat()
    NSColor.white.withAlphaComponent(0.22).setFill()
    NSBezierPath(roundedRect: phone, xRadius: 62, yRadius: 62).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.05, green: 0.55, blue: 0.91, alpha: 0),
               ending: NSColor(calibratedRed: 0.05, green: 0.60, blue: 0.91, alpha: 0.9))!
        .draw(in: NSRect(x: 60, y: 60, width: 904, height: 270), angle: -90)

    // Phone body
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 36; shadow.shadowOffset = NSSize(width: 0, height: -14)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: phone, xRadius: 62, yRadius: 62).fill()
    NSGraphicsContext.restoreGraphicsState()
    // Screen
    let screen = phone.insetBy(dx: 26, dy: 26)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 40, yRadius: 40)
    NSGradient(colors: [NSColor(calibratedRed: 0.11, green: 0.10, blue: 0.30, alpha: 1),
                        NSColor(calibratedRed: 0.20, green: 0.17, blue: 0.55, alpha: 1)])!.draw(in: screenPath, angle: -90)
    // Camera
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSBezierPath(ovalIn: NSRect(x: phone.midX - 11, y: screen.maxY - 44, width: 22, height: 22)).fill()
    // "JH"
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let text = NSAttributedString(string: "JH", attributes: [
        .font: NSFont.systemFont(ofSize: 190, weight: .heavy),
        .foregroundColor: NSColor.white,
        .kern: -4,
        .paragraphStyle: style])
    let size = text.size()
    text.draw(in: NSRect(x: screen.minX, y: screen.midY - size.height / 2 + 10, width: screen.width, height: size.height))
    // Connection waves
    NSColor.white.setStroke()
    for (radius, alpha) in [(70.0, 0.95), (112.0, 0.6)] {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: phone.maxX + 6, y: phone.maxY - 70), radius: CGFloat(radius), startAngle: -50, endAngle: 50)
        arc.lineWidth = 22; arc.lineCapStyle = .round
        NSColor.white.withAlphaComponent(CGFloat(alpha)).setStroke(); arc.stroke()
    }
}

func render(_ pixels: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    drawIcon(in: NSGraphicsContext.current!.cgContext, pixels: pixels)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = root.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),
    ("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),
    ("icon_512x512",512),("icon_512x512@2x",1024)]
for (name, pixels) in sizes {
    try render(pixels).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name + ".png"))
}
let android = root.appendingPathComponent("android/res/drawable", isDirectory: true)
try FileManager.default.createDirectory(at: android, withIntermediateDirectories: true)
try render(192).representation(using: .png, properties: [:])!.write(to: android.appendingPathComponent("app_icon.png"))
try render(64).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("packaging/AppIcon64.png"))
