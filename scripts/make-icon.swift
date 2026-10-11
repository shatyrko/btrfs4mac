// Generates Resources/AppIcon.icns. Usage: swift scripts/make-icon.swift
// An original drawing (no Apple SF Symbols, which may not be used in app icons): everything is a vector
// path, rendered separately at each size so edges stay sharp.
import AppKit

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

func softShadow(blur: CGFloat, dy: CGFloat, alpha: CGFloat) -> NSShadow {
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: dy)
    return shadow
}

/// Draws the icon in a 1024 x 1024 coordinate space.
func drawIcon() {
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    softShadow(blur: 28, dy: -12, alpha: 0.35).set()
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

    // A hard disk: silver platter with rings, a hub and the actuator arm.
    let center = NSPoint(x: 450, y: 585)
    let radius: CGFloat = 275
    let platter = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    NSGraphicsContext.saveGraphicsState()
    softShadow(blur: 34, dy: -18, alpha: 0.45).set()
    NSColor.white.setFill()
    platter.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    platter.addClip()
    NSGradient(colors: [rgb(1, 1, 1), rgb(0.86, 0.90, 0.96), rgb(0.62, 0.69, 0.80)],
               atLocations: [0, 0.6, 1], colorSpace: .sRGB)!
        .draw(fromCenter: NSPoint(x: center.x - 50, y: center.y + 60), radius: 10, toCenter: center, radius: radius, options: [])
    // two soft light wedges, like a polished surface
    NSColor.white.withAlphaComponent(0.35).setFill()
    for start in [25.0, 205.0] {
        let wedge = NSBezierPath()
        wedge.move(to: center)
        wedge.appendArc(withCenter: center, radius: radius, startAngle: CGFloat(start), endAngle: CGFloat(start + 38))
        wedge.close()
        wedge.fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // concentric tracks
    rgb(0.10, 0.26, 0.68, 0.22).setStroke()
    for r in [215.0, 165.0, 115.0] {
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        ring.lineWidth = 7
        ring.stroke()
    }
    // hub
    rgb(0.10, 0.20, 0.46, 0.85).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 62, y: center.y - 62, width: 124, height: 124)).fill()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44)).fill()

    // actuator arm
    let pivot = NSPoint(x: 745, y: 770)
    let arm = NSBezierPath()
    arm.move(to: NSPoint(x: pivot.x + 6, y: pivot.y + 22))
    arm.line(to: NSPoint(x: 560, y: 640))
    arm.line(to: NSPoint(x: 530, y: 612))
    arm.line(to: NSPoint(x: 548, y: 600))
    arm.line(to: NSPoint(x: pivot.x - 22, y: pivot.y - 10))
    arm.close()
    NSGraphicsContext.saveGraphicsState()
    softShadow(blur: 14, dy: -8, alpha: 0.4).set()
    rgb(0.13, 0.16, 0.27).setFill()
    arm.fill()
    NSGraphicsContext.restoreGraphicsState()
    rgb(0.13, 0.16, 0.27).setFill()
    NSBezierPath(ovalIn: NSRect(x: pivot.x - 36, y: pivot.y - 36, width: 72, height: 72)).fill()
    rgb(0.70, 0.76, 0.88).setFill()
    NSBezierPath(ovalIn: NSRect(x: pivot.x - 14, y: pivot.y - 14, width: 28, height: 28)).fill()

    // Lock badge.
    let badge = NSRect(x: 575, y: 215, width: 270, height: 270)
    NSGraphicsContext.saveGraphicsState()
    softShadow(blur: 16, dy: -8, alpha: 0.35).set()
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
