import AppKit

struct DashboardData {
    var name = Config.diskName
    var mountPoint = Config.mountPoint
    var used: Double = 0
    var total: Double = 0
    var errors: Int?
    var activity: ActivitySampler.Activity = .idle
    var written: UInt64?
    var read: UInt64?
    /// Bytes per second, one sample a second, oldest first.
    var reads: [Double] = []
    var writes: [Double] = []
}

/// The card at the top of the menu: drive, health, space, live throughput and totals.
final class DashboardView: NSView {
    static let historyLength = 60
    static let size = NSSize(width: 330, height: 188)

    var data = DashboardData() { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    private let margin: CGFloat = 16
    /// Fixed blue from the app icon: the system accent colour can be grey.
    private let brand = NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1)
    private let writeColor = NSColor.systemOrange
    private let readColor = NSColor.systemTeal

    init() { super.init(frame: NSRect(origin: .zero, size: Self.size)) }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Drawing helpers

    private func draw(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, rightAligned: Bool = false, monospaced: Bool = false) {
        let font = monospaced ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                              : NSFont.systemFont(ofSize: size, weight: weight)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let width = string.size().width
        string.draw(at: NSPoint(x: rightAligned ? point.x - width : point.x, y: point.y))
    }

    private func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).size().width
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width
        let inner = width - 2 * margin

        // Header: icon, name, state, health.
        if let icon = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .semibold)
                .applying(.init(paletteColors: [brand]))) {
            icon.draw(in: NSRect(x: margin, y: 12, width: icon.size.width, height: icon.size.height))
        }
        draw(data.name, at: NSPoint(x: margin + 34, y: 10), size: 14, weight: .semibold)
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: NSRect(x: margin + 34, y: 31, width: 7, height: 7)).fill()
        draw("Mounted at \(data.mountPoint)", at: NSPoint(x: margin + 46, y: 28), size: 11, color: .secondaryLabelColor)

        if let errors = data.errors {
            let ok = errors == 0
            let label = ok ? "No errors" : "\(errors) errors"
            let color: NSColor = ok ? .systemGreen : .systemRed
            let w = textWidth(label, size: 11, weight: .medium) + 26
            let pill = NSRect(x: width - margin - w, y: 13, width: w, height: 20)
            color.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10).fill()
            if let shield = NSImage(systemSymbolName: ok ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
                                    accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold).applying(.init(paletteColors: [color]))) {
                shield.draw(in: NSRect(x: pill.minX + 7, y: pill.minY + 4, width: shield.size.width, height: shield.size.height))
            }
            draw(label, at: NSPoint(x: pill.minX + 21, y: pill.minY + 3), size: 11, weight: .medium, color: color)
        }

        // Space bar.
        let fraction = data.total > 0 ? min(max(data.used / data.total, 0), 1) : 0
        let barY: CGFloat = 56
        let track = NSRect(x: margin, y: barY, width: inner, height: 10)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()
        if data.used > 0 {
            let fill = NSRect(x: margin, y: barY, width: max(10, inner * fraction), height: 10)
            let tint: NSColor = fraction > 0.92 ? .systemRed : (fraction > 0.8 ? .systemOrange : brand)
            NSGradient(starting: tint.withAlphaComponent(0.7), ending: tint)!
                .draw(in: NSBezierPath(roundedRect: fill, xRadius: 5, yRadius: 5), angle: 0)
        }
        let percent = String(format: "%.1f%%", fraction * 100)
        draw("\(formatBytes(data.used)) used · \(percent)", at: NSPoint(x: margin, y: barY + 15), size: 11, weight: .medium,
             monospaced: true)
        draw("\(formatBytes(max(data.total - data.used, 0))) free of \(formatBytes(data.total))",
             at: NSPoint(x: width - margin, y: barY + 15), size: 11, color: .secondaryLabelColor,
             rightAligned: true, monospaced: true)

        // Activity graph.
        let panel = NSRect(x: margin, y: 100, width: inner, height: 54)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 9, yRadius: 9).fill()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: panel, xRadius: 9, yRadius: 9).addClip()
        let peak = max(1_000_000, (data.reads + data.writes).max() ?? 0)
        let graph = NSRect(x: panel.minX, y: panel.minY + 20, width: panel.width, height: panel.height - 22)
        drawSeries(data.writes, peak: peak, in: graph, color: writeColor)
        drawSeries(data.reads, peak: peak, in: graph, color: readColor)
        NSGraphicsContext.restoreGraphicsState()

        var x = panel.minX + 10
        for (text, color) in activityParts() {
            draw(text, at: NSPoint(x: x, y: panel.minY + 5), size: 12, weight: .semibold, color: color, monospaced: true)
            x += NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])
                .size().width + 12
        }
        draw("last \(Self.historyLength) s", at: NSPoint(x: panel.maxX - 10, y: panel.minY + 6), size: 10,
             color: .tertiaryLabelColor, rightAligned: true)

        // Totals.
        let totalsY: CGFloat = 162
        if let written = data.written, let read = data.read {
            writeColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: margin, y: totalsY + 4, width: 8, height: 8)).fill()
            draw("\(formatBytes(Double(written))) written", at: NSPoint(x: margin + 14, y: totalsY), size: 12,
                 weight: .medium, monospaced: true)
            readColor.setFill()
            let readText = "\(formatBytes(Double(read))) read"
            let readX = width - margin - textWidth(readText, size: 12, weight: .medium)
            NSBezierPath(ovalIn: NSRect(x: readX - 14, y: totalsY + 4, width: 8, height: 8)).fill()
            draw(readText, at: NSPoint(x: width - margin, y: totalsY), size: 12, weight: .medium,
                 rightAligned: true, monospaced: true)
        }
    }

    private func activityParts() -> [(String, NSColor)] {
        guard case .active(let r, let w) = data.activity else { return [("Idle", .secondaryLabelColor)] }
        var parts: [(String, NSColor)] = []
        if w > 0 { parts.append(("↑ \(formatRate(w))", writeColor)) }
        if r > 0 { parts.append(("↓ \(formatRate(r))", readColor)) }
        return parts
    }

    /// A filled area with a line on top; `values` are right-aligned so new data enters from the right.
    private func drawSeries(_ values: [Double], peak: Double, in rect: NSRect, color: NSColor) {
        guard values.count > 1 else { return }
        let step = rect.width / CGFloat(Self.historyLength - 1)
        let startX = rect.maxX - step * CGFloat(values.count - 1)
        func point(_ i: Int) -> NSPoint {
            NSPoint(x: startX + step * CGFloat(i), y: rect.maxY - CGFloat(values[i] / peak) * rect.height)
        }
        let line = NSBezierPath()
        line.move(to: point(0))
        for i in 1..<values.count { line.line(to: point(i)) }
        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        area.line(to: NSPoint(x: startX, y: rect.maxY))
        area.close()
        color.withAlphaComponent(0.28).setFill()
        area.fill()
        color.setStroke()
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        line.stroke()
    }
}
