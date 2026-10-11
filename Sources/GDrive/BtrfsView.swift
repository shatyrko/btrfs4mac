import AppKit

/// A slim progress bar in the app's blue (the system accent colour can be grey).
final class BarView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 8) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let width = max(8, bounds.width * CGFloat(min(max(fraction, 0), 1)))
        guard fraction > 0 else { return }
        let brand = NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1)
        NSGradient(starting: brand.withAlphaComponent(0.7), ending: brand)!
            .draw(in: NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                                   xRadius: 4, yRadius: 4), angle: 0)
    }
}

final class ClosureButton: NSButton {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}

/// The Btrfs card: subvolumes, snapshots and the data check, with buttons on every row.
final class BtrfsView: NSView {
    struct Actions {
        var openSubvolume: (String) -> Void = { _ in }
        var snapshotSubvolume: (String) -> Void = { _ in }
        var newSubvolume: () -> Void = {}
        var snapshotAll: () -> Void = {}
        var openSnapshot: (String) -> Void = { _ in }
        var deleteSnapshot: (String) -> Void = { _ in }
        var toggleScrub: () -> Void = {}
    }

    static let width: CGFloat = 340
    private let maxSnapshots = 6

    var actions = Actions()
    private let stack = NSStackView()
    private var signature = ""
    private var info: BtrfsInfo?
    private let scrubLabel = NSTextField(labelWithString: "")
    private let scrubBar = BarView()
    private var scrubButton: ClosureButton?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 120))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width)
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Updating

    func update(_ info: BtrfsInfo?) {
        self.info = info
        let sig = ((info?.subvolumes ?? []) + ["|"] + (info?.snapshots ?? [])).joined(separator: "\n") + "\(info == nil)"
        if sig != signature {
            signature = sig
            rebuild()
        } else {
            updateScrub()
        }
    }

    private func updateScrub() {
        guard let info else { return }
        scrubLabel.stringValue = info.scrub
        scrubBar.isHidden = !info.scrubRunning
        scrubBar.fraction = (info.scrubPercent ?? 0) / 100
        scrubButton?.image = symbol(info.scrubRunning ? "stop.circle.fill" : "play.circle.fill", size: 15)
        scrubButton?.toolTip = info.scrubRunning ? "Cancel the data check"
                                                 : "Check all data against its checksums (takes hours)"
    }

    private func rebuild() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }

        guard let info else {
            add(label("Loading…", size: 12, color: .secondaryLabelColor))
            finishLayout()
            return
        }

        // Subvolumes
        add(sectionHeader("SUBVOLUMES", button: button("plus.circle.fill", "New subvolume") { [weak self] in self?.actions.newSubvolume() }))
        if info.subvolumes.isEmpty {
            add(label("None yet. Create one with +", size: 12, color: .secondaryLabelColor))
        }
        for path in info.subvolumes {
            add(row(icon: "folder.fill", tint: NSColor.systemBlue, title: path, subtitle: nil, buttons: [
                button("folder", "Open in Finder") { [weak self] in self?.actions.openSubvolume(path) },
                button("camera.fill", "Take a snapshot of \(path)") { [weak self] in self?.actions.snapshotSubvolume(path) }
            ]))
        }
        add(divider())

        // Snapshots
        add(sectionHeader("SNAPSHOTS", button: button("camera.on.rectangle.fill", "Snapshot everything") { [weak self] in
            self?.actions.snapshotAll()
        }))
        if info.snapshots.isEmpty {
            add(label("None yet", size: 12, color: .secondaryLabelColor))
        }
        for name in info.snapshots.prefix(maxSnapshots) {
            let (title, age) = describeSnapshot(name)
            add(row(icon: "clock.arrow.circlepath", tint: NSColor.systemOrange, title: title, subtitle: age, buttons: [
                button("folder", "Open in Finder") { [weak self] in self?.actions.openSnapshot(name) },
                button("trash", "Delete this snapshot") { [weak self] in self?.actions.deleteSnapshot(name) }
            ]))
        }
        if info.snapshots.count > maxSnapshots {
            add(label("and \(info.snapshots.count - maxSnapshots) older", size: 11, color: .tertiaryLabelColor))
        }
        add(divider())

        // Data check
        let scrub = button("play.circle.fill", "") { [weak self] in self?.actions.toggleScrub() }
        scrubButton = scrub
        add(sectionHeader("DATA CHECK", button: scrub))
        scrubLabel.font = .systemFont(ofSize: 12)
        scrubLabel.textColor = .labelColor
        scrubLabel.lineBreakMode = .byTruncatingTail
        add(scrubLabel)
        add(scrubBar)
        updateScrub()
        finishLayout()
    }

    private func finishLayout() {
        layoutSubtreeIfNeeded()
        setFrameSize(NSSize(width: Self.width, height: stack.fittingSize.height))
    }

    // MARK: Building blocks

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    private func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }

    private func button(_ symbolName: String, _ tip: String, _ handler: @escaping () -> Void) -> ClosureButton {
        let b = ClosureButton()
        b.image = symbol(symbolName, size: 14)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        b.handler = handler
        b.target = b
        b.action = #selector(ClosureButton.fire)
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private func sectionHeader(_ title: String, button: NSButton) -> NSView {
        let text = label(title, size: 10, weight: .semibold, color: .secondaryLabelColor)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [text, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        return row
    }

    private func row(icon: String, tint: NSColor, title: String, subtitle: String?, buttons: [NSButton]) -> NSView {
        let image = NSImageView(image: symbol(icon, size: 14) ?? NSImage())
        image.contentTintColor = tint
        image.setContentHuggingPriority(.required, for: .horizontal)
        image.widthAnchor.constraint(equalToConstant: 18).isActive = true

        var texts: [NSView] = [label(title, size: 12, weight: .medium)]
        if let subtitle { texts.append(label(subtitle, size: 10, color: .secondaryLabelColor)) }
        let text = NSStackView(views: texts)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [image, text] + buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        return row
    }

    private func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    /// "2026-10-11_170015-Documents" → ("Documents", "2 hr. ago"); a bare time stamp is the whole volume.
    private func describeSnapshot(_ name: String) -> (String, String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        guard name.count >= 17, let date = formatter.date(from: String(name.prefix(17))) else { return (name, "") }
        var title = String(name.dropFirst(17))
        if title.hasPrefix("-") { title.removeFirst() }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        return (title.isEmpty ? "Everything" : title, relative.localizedString(for: date, relativeTo: Date()))
    }
}
