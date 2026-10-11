// Generates Resources/AppIcon.icns. Usage: swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024

func symbol(_ name: String, points: CGFloat, color: NSColor) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: points, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

func master() -> NSImage {
    NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { rect in
        // Icon body on the standard macOS grid, with a soft shadow.
        let body = NSRect(x: 100, y: 100, width: 824, height: 824)
        let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        NSColor(calibratedRed: 0.05, green: 0.12, blue: 0.30, alpha: 1).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.62, blue: 0.95, alpha: 1),
                            NSColor(calibratedRed: 0.10, green: 0.26, blue: 0.68, alpha: 1),
                            NSColor(calibratedRed: 0.05, green: 0.10, blue: 0.34, alpha: 1)],
                   atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
            .draw(in: body, angle: -90)
        // soft highlight on the upper half
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // The drive.
        let drive = symbol("externaldrive.fill", points: 420, color: .white)
        let size = drive.size
        let driveRect = NSRect(x: (canvas - size.width) / 2 - 30, y: (canvas - size.height) / 2 + 55,
                               width: size.width, height: size.height)
        drive.draw(in: driveRect)

        // Lock badge.
        let badge = NSRect(x: 575, y: 215, width: 270, height: 270)
        NSGraphicsContext.saveGraphicsState()
        let badgeShadow = NSShadow()
        badgeShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        badgeShadow.shadowBlurRadius = 16
        badgeShadow.shadowOffset = NSSize(width: 0, height: -8)
        badgeShadow.set()
        NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.22, alpha: 1).setFill()
        NSBezierPath(ovalIn: badge).fill()
        NSGraphicsContext.restoreGraphicsState()
        let lock = symbol("lock.fill", points: 150, color: NSColor(calibratedRed: 0.28, green: 0.17, blue: 0.0, alpha: 1))
        lock.draw(in: NSRect(x: badge.midX - lock.size.width / 2, y: badge.midY - lock.size.height / 2,
                             width: lock.size.width, height: lock.size.height))
        return true
    }
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = "build/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let image = master()
for base in [16, 32, 128, 256, 512] {
    try! png(image, pixels: base).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base).png"))
    try! png(image, pixels: base * 2).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)@2x.png"))
}
try! png(image, pixels: 1024).write(to: URL(fileURLWithPath: "build/icon-preview.png"))
