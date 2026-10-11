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
    private var drive: DriveInfo?
    private var driveChoices: [DriveInfo] = []
    private var sampler = ActivitySampler()
    private var activity: ActivitySampler.Activity = .idle
    private var dashboard: DashboardView?
    private var space: (size: Double, free: Double)?
    private var readHistory: [Double] = []
    private var writeHistory: [Double] = []
    private var promptedFor: String?
    private var backingUp = false
    private var missingStrikes = 0
    private var latestRelease: Release?
    private var btrfsInfo: BtrfsInfo?
    private weak var btrfsCard: BtrfsView?
    private var btrfsTimer: Timer?
    private var subvolumeSizes: [String: Double] = [:]
    private var sizesPaths: [String] = []
    private var sizesFetchedAt: Date?
    private var sizesBusy = false
    private let scrubRun = ScrubRun()
    private var scrubStartRead: UInt64?
    private var scrubTotal: Double?
    private var lastScrub: String {
        get { UserDefaults.standard.string(forKey: "lastScrub") ?? "Never run" }
        set { UserDefaults.standard.set(newValue, forKey: "lastScrub") }
    }
    private var openMenu: NSMenu?

    private var driveName: String { drive?.name ?? Config.pinnedDiskName ?? "Drive" }

    private var keepAliveEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "keepAlive") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepAlive") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        migrateFromGDrive()
        Askpass.install()
        log("started \(Versions.app) (\(Versions.build))")
        checkForUpdates()
        let daily = Timer(timeInterval: 12 * 3600, repeats: true) { [weak self] _ in self?.checkForUpdates() }
        RunLoop.main.add(daily, forMode: .common)
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
            let all = findDrives()
            var found: DriveInfo?
            if let pinned = Config.pinnedDiskName { found = all.first { $0.name == pinned } } else { found = all.first }
            let space = mounted ? spaceNumbers() : nil
            DispatchQueue.main.async {
                self.driveChoices = all
                if case .busy = self.state { return }
                if mounted {
                    // A mount is dead when the drive came back under another name (sure sign),
                    // or when it stayed missing for several checks in a row (diskutil can fail once).
                    if let found, found.partition != device {
                        log("stale mount: mounted from \(device ?? "?"), drive is now \(found.partition)")
                        self.resetStaleMount()
                        return
                    }
                    if found == nil {
                        self.missingStrikes += 1
                        if self.missingStrikes >= 5 {
                            log("stale mount: drive missing in \(self.missingStrikes) checks in a row")
                            self.missingStrikes = 0
                            self.resetStaleMount()
                        }
                        return
                    }
                    self.missingStrikes = 0
                    if let space { self.space = space }
                    self.drive = found
                    self.state = .mounted
                    if self.keepAliveEnabled { self.keepAlive.start() }
                } else {
                    self.keepAlive.stop()
                    self.sampler.reset()
                    self.activity = .idle
                    self.readHistory = []
                    self.writeHistory = []
                    self.space = nil
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
        log("resetting stale mount")
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
        var read = 0.0, write = 0.0
        if case .active(let r, let w) = activity { read = r; write = w }
        readHistory = Array((readHistory + [read]).suffix(DashboardView.historyLength))
        writeHistory = Array((writeHistory + [write]).suffix(DashboardView.historyLength))
        updateIcon()
        dashboard?.data = dashboardData()
    }

    private func dashboardData() -> DashboardData {
        var d = DashboardData()
        d.name = driveName
        d.mountPoint = Config.mountPoint
        if let space {
            d.total = space.size
            d.used = max(space.size - space.free, 0)
        }
        d.errors = btrfsInfo?.errors
        d.activity = activity
        d.written = sampler.totals?.written
        d.read = sampler.totals?.read
        d.reads = readHistory
        d.writes = writeHistory
        return d
    }

    private func updateIcon() {
        let symbol: String
        switch state {
        case .notConnected: symbol = "externaldrive.badge.xmark"
        case .locked: symbol = "lock.fill"
        case .busy: symbol = "hourglass"
        case .mounted: symbol = "externaldrive.fill"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "btrfs4mac")
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
        reloadBtrfs()
        // Keep the Btrfs card and the health badge fresh while the menu stays open.
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.reloadBtrfs() }
        RunLoop.main.add(timer, forMode: .common)
        btrfsTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        dashboard = nil
        btrfsCard = nil
        btrfsTimer?.invalidate()
        btrfsTimer = nil
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

    /// Only shown when more than one drive could be the Btrfs one.
    private func addDriveChooser(to menu: NSMenu) {
        guard driveChoices.count > 1 || (driveChoices.count == 1 && drive == nil) else { return }
        let sub = addSubmenu(to: menu, "Choose Drive", icon: "externaldrive")
        for choice in driveChoices {
            let item = add(to: sub, "\(choice.name) · \(formatBytes(choice.size)) · \(choice.partition)",
                           icon: "externaldrive.fill", #selector(chooseDrive(_:)))
            item.representedObject = choice.name
            item.state = choice.partition == drive?.partition ? .on : .off
        }
    }

    @objc private func chooseDrive(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        UserDefaults.standard.set(name, forKey: "diskName")
        promptedFor = nil
        refresh()
    }

    private func addHeaderMenu(to menu: NSMenu) {
        let sub = addSubmenu(to: menu, "LUKS Header", icon: "key.horizontal.fill")
        add(to: sub, "Back Up…", icon: "square.and.arrow.down", #selector(backupHeader))
        add(to: sub, "Verify Backup…", icon: "checkmark.shield", #selector(verifyHeader))
    }

    private func addBtrfsMenu(to menu: NSMenu) {
        let card = BtrfsView()
        // Buttons act once the menu has closed, so dialogs and Finder windows are not left behind it.
        func later(_ work: @escaping () -> Void) {
            openMenu?.cancelTracking()
            DispatchQueue.main.async(execute: work)
        }
        card.actions = BtrfsView.Actions(
            openSubvolume: { path in later { [weak self] in self?.openSubvolume(path) } },
            snapshotSubvolume: { path in later { [weak self] in self?.runSnapshot(only: path) } },
            newSubvolume: { later { [weak self] in self?.newSubvolume() } },
            snapshotAll: { later { [weak self] in self?.runSnapshot(only: nil) } },
            openSnapshot: { name in later { [weak self] in self?.openSnapshot(name) } },
            deleteSnapshot: { name in later { [weak self] in self?.confirmDeleteSnapshot(name) } },
            toggleScrub: { later { [weak self] in self?.toggleScrub() } },
            refreshSizes: { [weak self] in self?.sizesFetchedAt = nil; self?.reloadBtrfs() }
        )
        card.update(btrfsInfo)
        btrfsCard = card
        let item = NSMenuItem()
        item.view = card
        menu.addItem(item)
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
            add(to: menu, Config.pinnedDiskName.map { "\($0) not connected" } ?? "No Btrfs drive found",
                icon: "externaldrive.badge.xmark")
            addDriveChooser(to: menu)
        case .locked(let partition, _):
            add(to: menu, "\(driveName) locked (\(partition))", icon: "lock.fill")
            addDriveChooser(to: menu)
            menu.addItem(.separator())
            add(to: menu, "Unlock and Mount…", icon: "lock.open.fill", #selector(unlock))
            addHeaderMenu(to: menu)
            add(to: menu, "Eject Drive", icon: "eject.fill", #selector(ejectOnly))
        case .busy(let what):
            add(to: menu, what, icon: "hourglass")
        case .mounted:
            let card = DashboardView()
            card.data = dashboardData()
            dashboard = card
            let cardItem = NSMenuItem()
            cardItem.view = card
            menu.addItem(cardItem)
            menu.addItem(.separator())
            add(to: menu, "Open in Finder", icon: "folder.fill", #selector(openFinder))
            add(to: menu, "Lock", icon: "lock.fill", #selector(lock))
            add(to: menu, "Lock and Eject Drive", icon: "eject.fill", #selector(lockAndEject))
            menu.addItem(.separator())
            addBtrfsMenu(to: menu)
            menu.addItem(.separator())
            let keep = add(to: menu, "Keep Drive Awake", icon: "heart.fill", #selector(toggleKeepAlive),
                           tip: "Writes a few bytes every \(Int(Config.keepAliveInterval)) s so the drive never idles; on by default")
            keep.state = keepAliveEnabled ? .on : .off
            let status = keepAliveStatus()
            add(to: menu, status.text, icon: status.ok ? "checkmark.circle" : "exclamationmark.triangle",
                tip: status.tip)
            addHeaderMenu(to: menu)
        }
        menu.addItem(.separator())
        add(to: menu, "Forget Saved Passphrase", icon: "key.slash",
            Keychain.load() != nil ? #selector(forgetPassphrase) : nil)
        add(to: menu, "About btrfs4mac…", icon: "info.circle", #selector(about))
        var quitTitle = "Quit"
        if case .notConnected = state {} else { quitTitle = "Eject Drive and Quit" }
        add(to: menu, quitTitle, icon: "eject.circle", #selector(quit),
            tip: "Unmounts the volume, stops the Linux VM, ejects the drive and quits the app")
        if let update = updateAvailable {
            let item = NSMenuItem(title: "Update available: anylinuxfs \(update.version)",
                                  action: #selector(openReleasePage), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
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
            log("unlock \(partition): exit \(result.status)")
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
        log("lock\(doEject ? " and eject" : "") requested")
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
        panel.message = "Where do you want to back up the LUKS header of \(driveName)? Keep it off this drive."
        panel.nameFieldStringValue = "\(driveName)-luks-header-\(day).img".replacingOccurrences(of: " ", with: "-")
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
            DispatchQueue.main.async {
                guard var info else { return }
                self.applyScrub(to: &info)
                self.refreshSizesIfNeeded(info.subvolumes)
                info.sizes = self.subvolumeSizes
                info.sizesBusy = self.sizesBusy
                self.btrfsInfo = info
                self.btrfsCard?.update(info)
                self.dashboard?.data = self.dashboardData()
            }
        }
    }

    private func runSnapshot(only: String?) {
        DispatchQueue.global().async {
            let result = takeSnapshot(only: only)
            DispatchQueue.main.async {
                self.reloadBtrfs()
                if result.ok {
                    self.show("Snapshot taken", "Read-only snapshot \(result.name) of \(only ?? "the volume and all its subvolumes") is in \(Config.mountPoint)/.snapshots. It takes almost no space until files change.")
                } else {
                    self.show("Could not take a snapshot", result.output)
                }
            }
        }
    }

    private func openSubvolume(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.mountPoint + "/" + path))
    }

    private func newSubvolume() {
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

    private func openSnapshot(_ name: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.mountPoint + "/.snapshots/" + name))
    }

    private func confirmDeleteSnapshot(_ name: String) {
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

    /// Subvolume sizes are slow to count on a big tree, so they are cached and recounted every ten minutes,
    /// when the list of subvolumes changes, or on request.
    private func refreshSizesIfNeeded(_ paths: [String]) {
        guard !paths.isEmpty, !sizesBusy else { return }
        let stale = sizesFetchedAt.map { Date().timeIntervalSince($0) > 600 } ?? true
        guard stale || Set(paths) != Set(sizesPaths) else { return }
        sizesBusy = true
        DispatchQueue.global().async {
            let sizes = fetchSubvolumeSizes(paths)
            DispatchQueue.main.async {
                self.subvolumeSizes = sizes
                self.sizesPaths = paths
                self.sizesFetchedAt = Date()
                self.sizesBusy = false
                self.reloadBtrfs()
            }
        }
    }

    /// btrfs cannot report scrub progress inside the VM, so it is estimated from the bytes read from the drive.
    private func applyScrub(to info: inout BtrfsInfo) {
        guard info.scrubRunning || scrubRun.isRunning else {
            info.scrub = lastScrub
            return
        }
        info.scrubRunning = true
        var bits = ["Running"]
        if let start = scrubStartRead, let total = scrubTotal, total > 0,
           let now = sampler.totals?.read, now >= start {
            let done = Double(now - start)
            let percent = min(done / total * 100, 99.9)
            info.scrubPercent = percent
            bits.append(String(format: "≈%.0f%%", percent))
            if case .active(let rate, _) = activity, rate > 1_000_000 {
                bits.append(formatRate(rate))
                let minutes = max(Int((total - done) / rate / 60), 1)
                bits.append(minutes >= 60 ? "~\(minutes / 60) h \(minutes % 60) min left" : "~\(minutes) min left")
            }
        }
        info.scrub = bits.joined(separator: " · ")
    }

    private func toggleScrub() {
        if btrfsInfo?.scrubRunning == true || scrubRun.isRunning {
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
        alert.informativeText = "A scrub reads everything and verifies the checksums. On a large drive it takes hours and slows other transfers. Locking the drive stops it."
        alert.addButton(withTitle: "Start Scrub")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let startRead = sampler.totals?.read
        DispatchQueue.global().async {
            let total = scrubTotalBytes()
            DispatchQueue.main.async {
                self.scrubTotal = total
                self.scrubStartRead = startRead
                do {
                    try self.scrubRun.start { summary in
                        self.scrubStartRead = nil
                        let when = DateFormatter()
                        when.dateStyle = .medium
                        when.timeStyle = .short
                        self.lastScrub = summary + " · " + when.string(from: Date())
                        log("scrub: \(self.lastScrub)")
                        self.reloadBtrfs()
                    }
                    log("scrub started")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.reloadBtrfs() }
                } catch {
                    self.show("Could not start the scrub", "\(error)")
                }
            }
        }
    }

    @objc private func forgetPassphrase() { Keychain.delete() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Quit

    /// Quitting unmounts the volume, stops the VM and ejects the drive, so nothing is left running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if case .busy = state {
            show("btrfs4mac is busy", "Wait for the current step to finish, then quit.")
            return .terminateCancel
        }
        let disk = drive?.disk ?? findDrive()?.disk
        let needsUnmount = isMounted() || vmProcessesRunning()
        guard needsUnmount || disk != nil else { return .terminateNow }

        if needsUnmount, case .active = activity {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Data is being transferred"
            alert.informativeText = "Quitting unmounts the drive, stops the Linux VM and ejects the drive. Wait until the transfer is done."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Unmount and Quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }

        log("quit: unmount=\(needsUnmount) eject=\(disk ?? "none")")
        keepAlive.stop()
        state = .busy("Unmounting and ejecting…")
        updateIcon()

        let finish = { [self] in
            guard let disk else { NSApp.reply(toApplicationShouldTerminate: true); return }
            run("/usr/sbin/diskutil", ["eject", "/dev/\(disk)"]) { [self] result in
                log("eject \(disk): exit \(result.status)")
                if result.status != 0 { show("Could not eject the drive", result.output) }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        if !needsUnmount { finish(); return .terminateLater }

        run(Config.anylinuxfs, ["unmount", "--wait-for-vm", "30"]) { [self] result in
            if !isMounted() && !vmProcessesRunning() { finish(); return }
            // Still mounted (files open?) or the VM did not exit: ask before forcing it.
            log("quit: unmount did not finish cleanly: \(result.output.suffix(200))")
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
            run(Config.anylinuxfs, ["stop"]) { _ in finish() }
        }
        return .terminateLater
    }

    // MARK: Updates and About

    private func checkForUpdates(then: (() -> Void)? = nil) {
        fetchLatestRelease { [self] release in
            if let release { latestRelease = release }
            then?()
        }
    }

    private var updateAvailable: Release? {
        guard let latest = latestRelease, let installed = Versions.anylinuxfs(),
              isNewer(latest.version, than: installed) else { return nil }
        return latest
    }

    @objc private func openReleasePage() {
        if let url = updateAvailable.flatMap({ URL(string: $0.url) }) { NSWorkspace.shared.open(url) }
    }

    @objc private func about() {
        checkForUpdates { [self] in
            let installed = Versions.anylinuxfs() ?? "not found"
            var vm = "anylinuxfs \(installed)"
            if let latest = latestRelease {
                vm += isNewer(latest.version, than: installed)
                    ? ", update available: \(latest.version)\nUpgrade with: brew update && brew upgrade anylinuxfs"
                    : ", up to date"
            } else {
                vm += ", could not check for updates"
            }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "btrfs4mac \(Versions.app)"
            alert.informativeText = "Build \(Versions.build)\n\nLinux VM (microVM): \(vm)"
            alert.addButton(withTitle: "OK")
            if updateAvailable != nil { alert.addButton(withTitle: "Release Page") }
            if alert.runModal() == .alertSecondButtonReturn { openReleasePage() }
        }
    }

    // MARK: Dialogs

    private func askPassphrase() -> (passphrase: String, remember: Bool)? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Unlock \(driveName)"
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
