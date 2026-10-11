import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State {
        case notConnected
        case locked(partition: String, disk: String)
        case busy(String)
        case mounted
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let keepAlive = KeepAlive()
    private var state: State = .notConnected
    private var drive: (disk: String, partition: String)?
    private var sampler = ActivitySampler()
    private var activity: ActivitySampler.Activity = .idle
    private var activityItem: NSMenuItem?
    private var promptedFor: String?

    private var keepAliveEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "keepAlive") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepAlive") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        refresh()
        let poll = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        let sampling = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sampleActivity() }
        RunLoop.main.add(poll, forMode: .common)
        RunLoop.main.add(sampling, forMode: .common)
    }

    // MARK: State

    private func refresh() {
        if case .busy = state { return }
        DispatchQueue.global().async {
            let mounted = isMounted()
            let device = mounted ? mountedDevice() : nil
            let found = findDrive()
            DispatchQueue.main.async {
                if case .busy = self.state { return }
                if mounted {
                    // The drive dropped off the bus and came back under another name:
                    // the mount is dead and has to be cleared before unlocking again.
                    if found == nil || found?.partition != device {
                        self.resetStaleMount()
                        return
                    }
                    self.drive = found
                    self.state = .mounted
                    if self.keepAliveEnabled { self.keepAlive.start() }
                } else {
                    self.keepAlive.stop()
                    self.sampler.reset()
                    self.activity = .idle
                    if let found {
                        self.drive = found
                        self.state = .locked(partition: found.partition, disk: found.disk)
                        // Plugged in and not yet asked about: unlock right away.
                        if self.promptedFor != found.partition {
                            self.promptedFor = found.partition
                            self.unlock()
                        }
                    } else {
                        self.drive = nil
                        self.promptedFor = nil
                        self.state = .notConnected
                    }
                }
                self.updateIcon()
            }
        }
    }

    private func resetStaleMount() {
        keepAlive.stop()
        sampler.reset()
        activity = .idle
        state = .busy("Drive reconnected, clearing old mount…")
        updateIcon()
        run(Config.anylinuxfs, ["unmount", "--wait-for-vm", "20"]) { [self] result in
            state = .notConnected
            if isMounted() {
                show("Could not clear the old mount", String(result.output.suffix(1200)))
                run(Config.anylinuxfs, ["stop"]) { _ in }
            }
            promptedFor = nil
            refresh()
        }
    }

    private func sampleActivity() {
        guard case .mounted = state, let disk = drive?.disk else { return }
        activity = sampler.sample(disk) ?? .idle
        updateIcon()
        activityItem?.title = activityTitle()
    }

    private func activityTitle() -> String {
        switch activity {
        case .idle:
            return "Idle"
        case .active(let r, let w):
            var parts: [String] = []
            if r > 0 { parts.append("reading \(formatRate(r))") }
            if w > 0 { parts.append("writing \(formatRate(w))") }
            return parts.joined(separator: ", ").capitalizedFirst
        }
    }

    private func updateIcon() {
        let symbol: String
        switch state {
        case .notConnected: symbol = "externaldrive.badge.xmark"
        case .locked: symbol = "lock.fill"
        case .busy: symbol = "hourglass"
        case .mounted: symbol = "externaldrive.fill"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "G-Drive")
        image?.isTemplate = true
        statusItem.button?.image = image

        var arrows = ""
        if case .active(let r, let w) = activity {
            arrows = " " + (r > 0 && w > 0 ? "↕" : (w > 0 ? "↑" : "↓"))
        }
        statusItem.button?.title = arrows
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        rebuild(menu)
    }

    func menuDidClose(_ menu: NSMenu) { activityItem = nil }

    @discardableResult
    private func add(to menu: NSMenu, _ title: String, icon: String, _ action: Selector? = nil,
                     tip: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = action != nil
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        menu.addItem(item)
        return item
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        switch state {
        case .notConnected:
            add(to: menu, "\(Config.diskName) not connected", icon: "externaldrive.badge.xmark")
        case .locked(let partition, _):
            add(to: menu, "\(Config.diskName) locked (\(partition))", icon: "lock.fill")
            menu.addItem(.separator())
            add(to: menu, "Unlock and Mount…", icon: "lock.open.fill", #selector(unlock))
            add(to: menu, "Eject Drive", icon: "eject.fill", #selector(ejectOnly))
        case .busy(let what):
            add(to: menu, what, icon: "hourglass")
        case .mounted:
            add(to: menu, "\(Config.diskName) mounted", icon: "externaldrive.fill.badge.checkmark",
                tip: Config.mountPoint)
            activityItem = add(to: menu, activityTitle(), icon: "arrow.up.arrow.down")
            menu.addItem(.separator())
            add(to: menu, "Open in Finder", icon: "folder.fill", #selector(openFinder))
            add(to: menu, "Lock", icon: "lock.fill", #selector(lock))
            add(to: menu, "Lock and Eject Drive", icon: "eject.fill", #selector(lockAndEject))
            menu.addItem(.separator())
            add(to: menu, keepAliveEnabled ? "Keep-alive on" : "Keep-alive off",
                icon: keepAliveEnabled ? "heart.fill" : "heart.slash", #selector(toggleKeepAlive))
            let status = keepAliveStatus()
            add(to: menu, status.text, icon: status.ok ? "checkmark.circle" : "exclamationmark.triangle",
                tip: status.tip)
        }
        menu.addItem(.separator())
        add(to: menu, "Forget Saved Passphrase", icon: "key.slash",
            Keychain.load() != nil ? #selector(forgetPassphrase) : nil)
        add(to: menu, "Quit G-Drive", icon: "power", #selector(quit))
    }

    private func keepAliveStatus() -> (text: String, ok: Bool, tip: String?) {
        guard keepAliveEnabled else { return ("Paused", true, nil) }
        if let error = keepAlive.lastError {
            return ("Last write failed", false, error)
        }
        if let ok = keepAlive.lastOK {
            let f = DateFormatter()
            f.timeStyle = .medium
            return ("Last write \(f.string(from: ok))", true, "Every \(Int(Config.keepAliveInterval)) s")
        }
        return ("Starting…", true, nil)
    }

    // MARK: Actions

    @objc private func unlock() {
        guard case .locked(let partition, _) = state else { return }
        var passphrase = Keychain.load()
        var remember = false
        if passphrase == nil {
            guard let answer = askPassphrase() else { return }
            passphrase = answer.passphrase
            remember = answer.remember
        }
        state = .busy("Unlocking…")
        updateIcon()
        run(Config.anylinuxfs, ["mount", "-w", "false", "--ignore-permissions", "/dev/\(partition)"],
            env: ["ALFS_PASSPHRASE": passphrase ?? ""]) { [self] result in
            state = .notConnected
            if result.status == 0 && isMounted() {
                if remember, let passphrase { Keychain.save(passphrase) }
                openFinder()
            } else {
                Keychain.delete()
                show("Could not mount", String(result.output.suffix(1200)))
            }
            refresh()
        }
    }

    @objc private func lock() { unmount(eject: false) }
    @objc private func lockAndEject() { unmount(eject: true) }

    @objc private func ejectOnly() {
        guard case .locked(_, let disk) = state else { return }
        eject(disk)
    }

    private func unmount(eject doEject: Bool) {
        let disk = drive?.disk
        keepAlive.stop()
        state = .busy("Unmounting…")
        activity = .idle
        updateIcon()
        run(Config.anylinuxfs, ["unmount", "--wait-for-vm", "30"]) { [self] result in
            state = .notConnected
            if result.status != 0 {
                show("Could not unmount", String(result.output.suffix(1200)))
            } else if doEject, let disk {
                eject(disk)
                return
            }
            refresh()
        }
    }

    private func eject(_ disk: String) {
        state = .busy("Ejecting…")
        updateIcon()
        run("/usr/sbin/diskutil", ["eject", "/dev/\(disk)"]) { [self] result in
            state = .notConnected
            if result.status != 0 { show("Could not eject", result.output) }
            refresh()
        }
    }

    @objc private func openFinder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.mountPoint))
    }

    @objc private func toggleKeepAlive() {
        keepAliveEnabled.toggle()
        if keepAliveEnabled { keepAlive.start() } else { keepAlive.stop() }
    }

    @objc private func forgetPassphrase() { Keychain.delete() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Dialogs

    private func askPassphrase() -> (passphrase: String, remember: Bool)? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Unlock \(Config.diskName)"
        alert.informativeText = "LUKS passphrase:"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 280, height: 24))
        let check = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
        check.frame = NSRect(x: 0, y: 0, width: 280, height: 20)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
        box.addSubview(field)
        box.addSubview(check)
        alert.accessoryView = box
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return (field.stringValue, check.state == .on)
    }

    private func show(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
