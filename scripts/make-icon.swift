import AppKit
let folder = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let n = CGFloat(size)
    NSColor(srgbRed: 0.96, green: 0.95, blue: 0.93, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: n * 0.07, y: n * 0.07, width: n * 0.86, height: n * 0.86), xRadius: n * 0.2, yRadius: n * 0.2).fill()
    let font = NSFont(name: "Georgia-Italic", size: n * 0.64) ?? .systemFont(ofSize: n * 0.64)
    let text = NSAttributedString(string: "π", attributes: [.font: font, .foregroundColor: NSColor(srgbRed: 217/255, green: 119/255, blue: 87/255, alpha: 1)])
    let extent = text.size()
    text.draw(at: NSPoint(x: (n-extent.width)/2 - n * 0.02, y: (n-extent.height)/2 + n * 0.015))
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let png = bitmap.representation(using: .png, properties: [:])!
    let names: [String]
    switch size {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
    default: names = ["icon_512x512@2x.png"]
    }
    for name in names { try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name)) }
}
