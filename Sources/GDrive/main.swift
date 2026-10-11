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
    private var backingUp = false
    private var btrfsInfo: BtrfsInfo?
    private var openMenu: NSMenu?

    private var keepAliveEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "keepAlive") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepAlive") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        Askpass.install()
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
        openMenu = menu
        refresh()
        rebuild(menu)
        guard case .mounted = state else { return }
        DispatchQueue.global().async {
            let info = fetchBtrfsInfo()
            DispatchQueue.main.async {
                guard let info else { return }
                self.btrfsInfo = info
                if let menu = self.openMenu { self.rebuild(menu) }
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        activityItem = nil
        openMenu = nil
    }

    private func addSubmenu(to menu: NSMenu, _ title: String, icon: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        let sub = NSMenu(title: title)
        item.submenu = sub
        menu.addItem(item)
        return sub
    }

    private func addHeaderMenu(to menu: NSMenu) {
        let sub = addSubmenu(to: menu, "LUKS Header", icon: "key.horizontal.fill")
        add(to: sub, "Back Up…", icon: "square.and.arrow.down", #selector(backupHeader))
        add(to: sub, "Verify Backup…", icon: "checkmark.shield", #selector(verifyHeader))
    }

    private func addBtrfsMenu(to menu: NSMenu) {
        let sub = addSubmenu(to: menu, "Btrfs", icon: "square.stack.3d.up.fill")
        let subs = addSubmenu(to: sub, "Subvolumes (\(btrfsInfo?.subvolumes.count ?? 0))", icon: "folder.badge.gearshape")
        if let paths = btrfsInfo?.subvolumes, !paths.isEmpty {
            for path in paths {
                let item = add(to: subs, path, icon: "folder", #selector(openSubvolume(_:)))
                item.representedObject = path
            }
        } else {
            add(to: subs, "None yet", icon: "tray")
        }
        subs.addItem(.separator())
        add(to: subs, "New Subvolume…", icon: "plus", #selector(newSubvolume))
        sub.addItem(.separator())
        add(to: sub, "Take Snapshot", icon: "camera.fill", #selector(snapshot))
        let snaps = addSubmenu(to: sub, "Snapshots (\(btrfsInfo?.snapshots.count ?? 0))", icon: "clock.arrow.circlepath")
        if let names = btrfsInfo?.snapshots, !names.isEmpty {
            for name in names {
                let one = addSubmenu(to: snaps, name, icon: "camera")
                let open = add(to: one, "Open in Finder", icon: "folder", #selector(openSnapshot(_:)))
                open.representedObject = name
                let del = add(to: one, "Delete…", icon: "trash", #selector(deleteSnapshotItem(_:)))
                del.representedObject = name
            }
        } else {
            add(to: snaps, "None yet", icon: "tray")
        }
        sub.addItem(.separator())
        let running = btrfsInfo?.scrubRunning == true
        add(to: sub, running ? "Cancel Scrub" : "Check Data Integrity (Scrub)…",
            icon: running ? "stop.circle" : "waveform.path.ecg", #selector(toggleScrub))
        add(to: sub, "Scrub: \(btrfsInfo?.scrub ?? "…")", icon: "info.circle")
    }

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
            addHeaderMenu(to: menu)
            add(to: menu, "Eject Drive", icon: "eject.fill", #selector(ejectOnly))
        case .busy(let what):
            add(to: menu, what, icon: "hourglass")
        case .mounted:
            add(to: menu, "\(Config.diskName) mounted", icon: "externaldrive.fill.badge.checkmark",
                tip: Config.mountPoint)
            activityItem = add(to: menu, activityTitle(), icon: "arrow.up.arrow.down")
            if let space = spaceUsage() {
                add(to: menu, space.used, icon: "chart.pie.fill")
                add(to: menu, space.free, icon: "chart.pie")
            }
            if let totals = sampler.totals {
                add(to: menu, "Since connected: \(formatBytes(Double(totals.written))) written, \(formatBytes(Double(totals.read))) read",
                    icon: "arrow.up.arrow.down.circle",
                    tip: "Counted by macOS for the drive since it was plugged in")
            }
            if let errors = btrfsInfo?.errors {
                add(to: menu, errors == 0 ? "No drive errors" : "\(errors) drive errors",
                    icon: errors == 0 ? "checkmark.shield" : "exclamationmark.triangle.fill",
                    tip: "btrfs device stats: read, write, flush, corruption and generation errors")
            }
            menu.addItem(.separator())
            add(to: menu, "Open in Finder", icon: "folder.fill", #selector(openFinder))
            add(to: menu, "Lock", icon: "lock.fill", #selector(lock))
            add(to: menu, "Lock and Eject Drive", icon: "eject.fill", #selector(lockAndEject))
            menu.addItem(.separator())
            addBtrfsMenu(to: menu)
            addHeaderMenu(to: menu)
            menu.addItem(.separator())
            let keep = add(to: menu, "Keep Drive Awake", icon: "heart.fill", #selector(toggleKeepAlive),
                           tip: "Writes a few bytes every \(Int(Config.keepAliveInterval)) s so the drive never idles; on by default")
            keep.state = keepAliveEnabled ? .on : .off
            let status = keepAliveStatus()
            add(to: menu, status.text, icon: status.ok ? "checkmark.circle" : "exclamationmark.triangle",
                tip: status.tip)
        }
        menu.addItem(.separator())
        add(to: menu, "Forget Saved Passphrase", icon: "key.slash",
            Keychain.load() != nil ? #selector(forgetPassphrase) : nil)
        add(to: menu, "Quit and Stop VM", icon: "power", #selector(quit))
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
        // Reading the raw disk needs root; sudo drops back to this user once the VM is up.
        run("/usr/bin/sudo", ["-A", "--preserve-env=ALFS_PASSPHRASE", Config.anylinuxfs,
                              "mount", "-w", "false", "--ignore-permissions", "/dev/\(partition)"],
            env: ["ALFS_PASSPHRASE": passphrase ?? "", "SUDO_ASKPASS": Askpass.path]) { [self] result in
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

    @objc private func backupHeader() {
        guard let partition = drive?.partition, !backingUp else { return }
        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let panel = NSSavePanel()
        panel.title = "Back Up LUKS Header"
        panel.message = "Where do you want to back up the LUKS header of \(Config.diskName)? Keep it off this drive."
        panel.nameFieldStringValue = "\(Config.diskName)-luks-header-\(day).img"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.path.hasPrefix(Config.mountPoint + "/") {
            show("Choose another place", "A header backup on the drive it protects is of no use if the drive fails.")
            return
        }
        backingUp = true
        DispatchQueue.global().async {
            let result = backupLUKSHeader(partition: partition, to: url)
            DispatchQueue.main.async {
                self.backingUp = false
                switch result {
                case .success(let size):
                    self.show("LUKS header saved", "\(url.path)\n\(size) bytes. Anyone who has this file and an old passphrase can unlock the drive, so keep it private.")
                case .failure(let error):
                    self.show("Could not back up the header", "\(error)")
                }
            }
        }
    }

    @objc private func verifyHeader() {
        guard let partition = drive?.partition, !backingUp else { return }
        let panel = NSOpenPanel()
        panel.title = "Verify LUKS Header Backup"
        panel.message = "Choose the saved header file to compare with the drive."
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backingUp = true
        DispatchQueue.global().async {
            let result = verifyHeaderBackup(partition: partition, file: url)
            DispatchQueue.main.async {
                self.backingUp = false
                switch result {
                case .matches(let size, let uuid):
                    self.show("Backup matches", "\(url.lastPathComponent) is identical to the header on the drive (\(size) bytes, LUKS UUID \(uuid)).")
                case .headerChanged(let uuid):
                    self.show("Backup is out of date", "Same drive (LUKS UUID \(uuid)), but the header has changed since this backup, for example after a passphrase or key change. Make a new backup.")
                case .otherDrive(let file, let drive):
                    self.show("Backup is from another drive", "The file is for LUKS UUID \(file), this drive is \(drive). Do not restore it here.")
                case .notAHeader:
                    self.show("Not a LUKS header", "\(url.lastPathComponent) does not look like a LUKS header backup.")
                case .failed(let text):
                    self.show("Could not verify", text)
                }
            }
        }
    }

    private func reloadBtrfs() {
        DispatchQueue.global().async {
            let info = fetchBtrfsInfo()
            DispatchQueue.main.async { if let info { self.btrfsInfo = info } }
        }
    }

    @objc private func snapshot() {
        DispatchQueue.global().async {
            let result = takeSnapshot()
            DispatchQueue.main.async {
                self.reloadBtrfs()
                if result.ok {
                    self.show("Snapshot taken", "Read-only snapshot \(result.name) of the volume and all its subvolumes is in \(Config.mountPoint)/.snapshots. It takes almost no space until files change.")
                } else {
                    self.show("Could not take a snapshot", result.output)
                }
            }
        }
    }

    @objc private func openSubvolume(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.mountPoint + "/" + path))
    }

    @objc private func newSubvolume() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "New subvolume"
        alert.informativeText = "Name (letters, digits, _ - and .):"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        let name = field.stringValue
        DispatchQueue.global().async {
            let result = createSubvolume(name)
            DispatchQueue.main.async {
                self.reloadBtrfs()
                if result.status != 0 { self.show("Could not create the subvolume", result.output) }
            }
        }
    }

    @objc private func openSnapshot(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.mountPoint + "/.snapshots/" + name))
    }

    @objc private func deleteSnapshotItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Delete snapshot \(name)?"
        alert.informativeText = "The files that exist only in this snapshot are gone for good."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global().async {
            let result = deleteSnapshot(name)
            DispatchQueue.main.async {
                self.reloadBtrfs()
                if result.status != 0 { self.show("Could not delete the snapshot", result.output) }
            }
        }
    }

    @objc private func toggleScrub() {
        if btrfsInfo?.scrubRunning == true {
            DispatchQueue.global().async {
                let result = cancelScrub()
                DispatchQueue.main.async {
                    self.reloadBtrfs()
                    if result.status != 0 { self.show("Could not cancel the scrub", result.output) }
                }
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Check all data on the drive?"
        alert.informativeText = "A scrub reads everything and verifies the checksums. On a large drive it takes many hours and slows other transfers. Locking the drive stops it."
        alert.addButton(withTitle: "Start Scrub")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global().async {
            let result = startScrub()
            DispatchQueue.main.async {
                self.reloadBtrfs()
                if result.status != 0 { self.show("Could not start the scrub", result.output) }
            }
        }
    }

    @objc private func forgetPassphrase() { Keychain.delete() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Quit

    /// Quitting unmounts the volume and stops the VM, so nothing is left running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if case .busy = state {
            show("G-Drive is busy", "Wait for the current step to finish, then quit.")
            return .terminateCancel
        }
        guard isMounted() || vmProcessesRunning() else { return .terminateNow }

        if case .active = activity {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Data is being transferred"
            alert.informativeText = "Quitting unmounts the drive and stops the Linux VM. Wait until the transfer is done."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Unmount and Quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }

        keepAlive.stop()
        state = .busy("Unmounting…")
        updateIcon()
        run(Config.anylinuxfs, ["unmount", "--wait-for-vm", "30"]) { [self] result in
            if !isMounted() && !vmProcessesRunning() {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            // Still mounted (files open?) or the VM did not exit: ask before forcing it.
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "The drive did not unmount cleanly"
            alert.informativeText = String(result.output.suffix(600)) + "\n\nForce Stop kills the VM; data not yet written is lost."
            alert.addButton(withTitle: "Stay Open")
            alert.addButton(withTitle: "Force Stop and Quit")
            if alert.runModal() == .alertFirstButtonReturn {
                state = .notConnected
                refresh()
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            run(Config.anylinuxfs, ["stop"]) { _ in
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

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
