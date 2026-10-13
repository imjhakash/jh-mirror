import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = root.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),
    ("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),
    ("icon_512x512",512),("icon_512x512@2x",1024)]
for (name, pixels) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 204, yRadius: 204)
    NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.53, blue: 0.98, alpha: 1),
               ending: NSColor(calibratedRed: 0.18, green: 0.27, blue: 0.82, alpha: 1))!.draw(in: tile, angle: -90)
    NSColor.white.setStroke()
    let phone = NSBezierPath(roundedRect: NSRect(x: 351, y: 232, width: 322, height: 560), xRadius: 59, yRadius: 59)
    phone.lineWidth = 31; phone.stroke()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 451, y: 744, width: 122, height: 17), xRadius: 8, yRadius: 8).fill()
    NSBezierPath(roundedRect: NSRect(x: 462, y: 266, width: 100, height: 17), xRadius: 8, yRadius: 8).fill()
    for radius: CGFloat in [85, 132] {
        let left = NSBezierPath(); left.appendArc(withCenter: NSPoint(x: 354, y: 520), radius: radius, startAngle: 145, endAngle: 215)
        left.lineWidth = 23; left.lineCapStyle = .round; left.stroke()
        let right = NSBezierPath(); right.appendArc(withCenter: NSPoint(x: 670, y: 520), radius: radius, startAngle: -35, endAngle: 35)
        right.lineWidth = 23; right.lineCapStyle = .round; right.stroke()
    }
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 642, y: 194, width: 131, height: 131)).fill()
    NSColor(calibratedRed: 0.14, green: 0.76, blue: 0.49, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 663, y: 215, width: 89, height: 89)).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name + ".png"))
}
let android = root.appendingPathComponent("android/res/drawable", isDirectory: true)
try FileManager.default.createDirectory(at: android, withIntermediateDirectories: true)
let icon = try Data(contentsOf: iconset.appendingPathComponent("icon_128x128.png"))
try icon.write(to: android.appendingPathComponent("app_icon.png"))
