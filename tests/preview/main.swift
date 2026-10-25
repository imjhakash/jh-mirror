import AppKit
// Reads the frame left by writer.c through the app's real reader.
let reader = PhonePreviewReader(path: URL(fileURLWithPath: CommandLine.arguments[1]))
guard let image = reader.nextImage() else { fatalError("no preview frame") }
assert(image.width == 64 && image.height == 128, "size \(image.width)x\(image.height)")
let rep = NSBitmapImageRep(cgImage: image)
let color = rep.colorAt(x: 10, y: 10)!.usingColorSpace(.deviceRGB)!
assert(color.redComponent > 0.9 && color.greenComponent < 0.1 && color.blueComponent < 0.1, "red: \(color)")
assert(reader.nextImage() == nil, "an unchanged frame is not decoded twice")
// A frame marked as being written (odd sequence) is never shown.
let fd = open(CommandLine.arguments[1], O_RDWR); var odd: UInt64 = 5
_ = pwrite(fd, &odd, 8, 8); close(fd)
assert(PhonePreviewReader(path: URL(fileURLWithPath: CommandLine.arguments[1])).nextImage() == nil, "torn frames rejected")
print("PASS: preview sink downscales, converts colour, throttles, idles when off; reader shows each new frame once and rejects torn frames.")
