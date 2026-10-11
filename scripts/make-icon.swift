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

    // An external drive: a slim aluminium slab seen from above-right, with a status light and a port.
    func quad(_ points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        path.close()
        return path
    }
    func fillRounded(_ path: NSBezierPath, _ gradient: NSGradient, angle: CGFloat, round: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        path.lineWidth = round
        path.lineJoinStyle = .round
        path.addClip()
        gradient.draw(in: path.bounds.insetBy(dx: -round, dy: -round), angle: angle)
        NSGraphicsContext.restoreGraphicsState()
    }
    // A stroke of the same colour with a round join gives the slab rounded corners.
    func roundedSolid(_ path: NSBezierPath, _ color: NSColor, round: CGFloat) {
        color.setFill()
        color.setStroke()
        path.lineWidth = round
        path.lineJoinStyle = .round
        path.fill()
        path.stroke()
    }

    let frontBL = NSPoint(x: 215, y: 470), frontBR = NSPoint(x: 715, y: 470)
    let frontTL = NSPoint(x: 215, y: 565), frontTR = NSPoint(x: 715, y: 565)
    let dx: CGFloat = 105, dy: CGFloat = 150
    let backTL = NSPoint(x: frontTL.x + dx, y: frontTL.y + dy), backTR = NSPoint(x: frontTR.x + dx, y: frontTR.y + dy)
    let sideBR = NSPoint(x: frontBR.x + dx, y: frontBR.y + dy)

    let top = quad([frontTL, frontTR, backTR, backTL])
    let front = quad([frontBL, frontBR, frontTR, frontTL])
    let side = quad([frontBR, sideBR, backTR, frontTR])

    NSGraphicsContext.saveGraphicsState()
    softShadow(blur: 36, dy: -22, alpha: 0.5).set()
    roundedSolid(quad([frontBL, frontBR, sideBR, backTR, backTL, frontTL]), rgb(0.55, 0.62, 0.74), round: 30)
    NSGraphicsContext.restoreGraphicsState()

    roundedSolid(side, rgb(0.50, 0.57, 0.70), round: 30)
    roundedSolid(front, rgb(0.72, 0.78, 0.87), round: 30)
    roundedSolid(top, rgb(0.93, 0.95, 0.98), round: 30)
    // light falling on the top face
    NSGraphicsContext.saveGraphicsState()
    top.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.9), NSColor.white.withAlphaComponent(0)])!
        .draw(in: top.bounds, angle: 60)
    NSGraphicsContext.restoreGraphicsState()
    // darker lower edge of the front face
    NSGraphicsContext.saveGraphicsState()
    front.addClip()
    NSGradient(colors: [rgb(0.55, 0.62, 0.76, 0), rgb(0.55, 0.62, 0.76, 0.55)])!
        .draw(in: front.bounds, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // status light and port on the front face
    rgb(0.30, 0.85, 0.45).setFill()
    NSBezierPath(roundedRect: NSRect(x: 255, y: 508, width: 70, height: 22), xRadius: 11, yRadius: 11).fill()
    rgb(0.10, 0.17, 0.35, 0.8).setFill()
    NSBezierPath(roundedRect: NSRect(x: 560, y: 505, width: 110, height: 28), xRadius: 14, yRadius: 14).fill()

    // Lock badge.
    let badge = NSRect(x: 600, y: 205, width: 250, height: 250)
    NSGraphicsContext.saveGraphicsState()
    softShadow(blur: 16, dy: -8, alpha: 0.35).set()
    rgb(1.0, 0.78, 0.22).setFill()
    NSBezierPath(ovalIn: badge).fill()
    NSGraphicsContext.restoreGraphicsState()

    let ink = rgb(0.28, 0.17, 0.0)
    ink.setFill()
    ink.setStroke()
    let cx = badge.midX
    NSBezierPath(roundedRect: NSRect(x: cx - 58, y: 250, width: 116, height: 96), xRadius: 18, yRadius: 18).fill()
    let shackle = NSBezierPath()
    shackle.move(to: NSPoint(x: cx - 34, y: 342))
    shackle.line(to: NSPoint(x: cx - 34, y: 372))
    shackle.appendArc(withCenter: NSPoint(x: cx, y: 372), radius: 34, startAngle: 180, endAngle: 0, clockwise: true)
    shackle.line(to: NSPoint(x: cx + 34, y: 342))
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
