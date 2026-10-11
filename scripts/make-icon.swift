// Generates Resources/AppIcon.icns. Usage: swift scripts/make-icon.swift
// The background and the lock are vector paths. The drive is the SF Symbol "externaldrive.fill", drawn at
// its exact pixel size for each icon size: scaling a cached symbol bitmap makes it blocky.
import AppKit

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

/// Draws the icon in a 1024 x 1024 coordinate space.
var drawDriveHook: (() -> Void)?

func drawIcon() {
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    rgb(0.05, 0.12, 0.30).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [rgb(0.20, 0.62, 0.95), rgb(0.10, 0.26, 0.68), rgb(0.05, 0.10, 0.34)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: body, angle: -90)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    drawDriveHook?()

    // Lock badge.
    let badge = NSRect(x: 575, y: 215, width: 270, height: 270)
    NSGraphicsContext.saveGraphicsState()
    let badgeShadow = NSShadow()
    badgeShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    badgeShadow.shadowBlurRadius = 16
    badgeShadow.shadowOffset = NSSize(width: 0, height: -8)
    badgeShadow.set()
    rgb(1.0, 0.78, 0.22).setFill()
    NSBezierPath(ovalIn: badge).fill()
    NSGraphicsContext.restoreGraphicsState()

    let ink = rgb(0.28, 0.17, 0.0)
    ink.setFill()
    ink.setStroke()
    let cx = badge.midX
    NSBezierPath(roundedRect: NSRect(x: cx - 62, y: 282, width: 124, height: 102), xRadius: 20, yRadius: 20).fill()
    let shackle = NSBezierPath()
    shackle.move(to: NSPoint(x: cx - 36, y: 380))
    shackle.line(to: NSPoint(x: cx - 36, y: 412))
    shackle.appendArc(withCenter: NSPoint(x: cx, y: 412), radius: 36, startAngle: 180, endAngle: 0, clockwise: true)
    shackle.line(to: NSPoint(x: cx + 36, y: 380))
    shackle.lineWidth = 24
    shackle.lineCapStyle = .round
    shackle.stroke()
}

/// The drive, drawn 1:1 in device pixels (no scaling), for an icon `pixels` wide.
func drawDrive(pixels: Int) {
    let scale = CGFloat(pixels) / 1024
    let config = NSImage.SymbolConfiguration(pointSize: 420 * scale, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return }
    let size = symbol.size
    let center = CGPoint(x: 470 * scale, y: 565 * scale)
    symbol.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                           width: size.width, height: size.height))
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true
    let scale = CGFloat(pixels) / 1024
    // The hook draws the drive between background and badge, in unscaled device pixels.
    drawDriveHook = {
        context.cgContext.saveGState()
        context.cgContext.scaleBy(x: 1 / scale, y: 1 / scale)
        drawDrive(pixels: pixels)
        context.cgContext.restoreGState()
    }
    context.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = "build/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(pixels: base).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base).png"))
    try! png(pixels: base * 2).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)@2x.png"))
}
try! png(pixels: 1024).write(to: URL(fileURLWithPath: "build/icon-preview.png"))
