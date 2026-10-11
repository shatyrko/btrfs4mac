import AppKit
import ServiceManagement

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
    private var poll: Timer?

    private var keepAliveEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "keepAlive") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepAlive") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refresh()
        poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: State

    private func refresh() {
        if case .busy = state { return }
        DispatchQueue.global().async {
            let mounted = isMounted()
            let found = mounted ? nil : findDrive()
            DispatchQueue.main.async {
                if case .busy = self.state { return }
                if mounted {
                    self.state = .mounted
                    if self.keepAliveEnabled { self.keepAlive.start() }
                } else {
                    self.keepAlive.stop()
                    if let found {
                        self.drive = found
                        self.state = .locked(partition: found.partition, disk: found.disk)
                    } else {
                        self.drive = nil
                        self.state = .notConnected
                    }
                }
                self.updateIcon()
            }
        }
    }

    private func updateIcon() {
        let symbol: String
        switch state {
        case .notConnected: symbol = "externaldrive.badge.xmark"
        case .locked: symbol = "externaldrive"
        case .busy: symbol = "externaldrive.badge.timemachine"
        case .mounted: symbol = "externaldrive.fill"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "G-Drive")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled && action != nil
            menu.addItem(item)
        }

        switch state {
        case .notConnected:
            add("\(Config.diskName): not connected", nil)
        case .locked(let partition, _):
            add("\(Config.diskName): locked (\(partition))", nil)
            menu.addItem(.separator())
            add("Unlock and Mount…", #selector(unlock))
            add("Eject Drive", #selector(ejectOnly))
        case .busy(let what):
            add(what, nil)
        case .mounted:
            add("\(Config.diskName): mounted at \(Config.mountPoint)", nil)
            menu.addItem(.separator())
            add("Open in Finder", #selector(openFinder))
            add("Lock (Unmount)", #selector(lock))
            add("Lock and Eject Drive", #selector(lockAndEject))
            menu.addItem(.separator())
            add(keepAliveEnabled ? "Keep-alive: on" : "Keep-alive: off",
                #selector(toggleKeepAlive))
            add(keepAliveStatus(), nil)
        }

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        add("Forget Saved Passphrase", #selector(forgetPassphrase), enabled: Keychain.load() != nil)
        add("Quit G-Drive", #selector(quit))
    }

    private func keepAliveStatus() -> String {
        guard keepAliveEnabled else { return "  paused" }
        if let error = keepAlive.lastError { return "  last write failed: \(error)" }
        if let ok = keepAlive.lastOK {
            let f = DateFormatter()
            f.timeStyle = .medium
            return "  last write \(f.string(from: ok)), every \(Int(Config.keepAliveInterval)) s"
        }
        return "  starting…"
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

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            show("Launch at Login", "\(error.localizedDescription)\n\nThe app must live in ~/Applications.")
        }
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
