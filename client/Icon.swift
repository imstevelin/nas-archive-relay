import AppKit
let folder = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
for (name, size) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let n = CGFloat(size)
    let rect = NSRect(x: n*0.055, y: n*0.055, width: n*0.89, height: n*0.89)
    let path = NSBezierPath(roundedRect: rect, xRadius: n*0.19, yRadius: n*0.19)
    NSGradient(starting: NSColor(red: 0.13, green: 0.35, blue: 0.90, alpha: 1), ending: NSColor(red: 0.24, green: 0.66, blue: 0.98, alpha: 1))!.draw(in: path, angle: 90)
    let configuration = NSImage.SymbolConfiguration(pointSize: n*0.51, weight: .medium).applying(.init(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: "arrow.up.doc.fill", accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
    symbol.draw(in: NSRect(x: n*0.25, y: n*0.22, width: n*0.50, height: n*0.59))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder+"/"+name+".png"))
}
