import AppKit

@MainActor final class DiagnosticDelegate: NSObject, NSApplicationDelegate {
    let monitor = ProcessMonitor()
    let coordinator = TaskbarCoordinator()
    let pinStore = PinStore()
    var storageReady = false
    let accessibility = AccessibilityService()
    let permissions = AccessibilityPermissionService()
    lazy var launcher = LaunchService(monitor: monitor)
    var window: NSWindow!
    let output = NSTextView()
    var selected: Instance?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit WMac!", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem(); item.submenu = applicationMenu; menu.addItem(item); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 760, height: 460),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "WMac! — Platform diagnostics"
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 12; stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let buttons = NSStackView()
        for (title, action) in [("Launch exact .app…", #selector(launchApp)), ("Refresh", #selector(refresh)),
                                ("Activate selected PID", #selector(activate)), ("Windows", #selector(windows)),
                                ("Enable Accessibility…", #selector(permission))] {
            buttons.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        stack.addArrangedSubview(buttons)
        let pinButtons = NSStackView()
        for (title, action) in [("Pin .app…", #selector(pinApp)), ("Unpin last", #selector(unpinLast)),
                                ("Move last pin first", #selector(moveLast)), ("Relink last pin…", #selector(relinkLast))] {
            pinButtons.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        stack.addArrangedSubview(pinButtons)
        let axButtons = NSStackView()
        for (title, action) in [("Test window toggle", #selector(toggleWindow)), ("Accessibility status", #selector(permissionStatus)), ("Accessibility settings…", #selector(permissionSettings))] {
            axButtons.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        stack.addArrangedSubview(axButtons)
        let explanation = NSTextField(labelWithString: "Diagnostic state snapshots with saved pins. Process action selection is the latest confirmed launch.")
        stack.addArrangedSubview(explanation)
        let scroll = NSScrollView(); scroll.documentView = output; scroll.hasVerticalScroller = true
        output.isEditable = false; output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(scroll)
        window.contentView = stack
        window.makeKeyAndOrderFront(nil)
        monitor.changed = { [weak self] values in
            guard let self else { return }
            self.coordinator.apply(values, active: self.monitor.activeInstance)
        }
        coordinator.changed = { [weak self] snapshot in self?.show(snapshot) }
        Task { @MainActor in
            do {
                let loaded = try await pinStore.load()
                coordinator.restore(loaded.pins)
                log("Loaded pins: \(loaded.pins.count), migrated: \(loaded.migrated)")
                storageReady = true
            } catch { log("Saved pins could not be loaded: \(error). Original file preserved; pin edits disabled.") }
        }
        refresh()
    }
    func log(_ line: String) { output.string += line + "\n"; output.scrollToEndOfDocument(nil) }
    @objc func refresh() {
        monitor.refresh()
        log("AX trusted: \(accessibility.trusted). Regular processes: \(monitor.snapshot.count)")

    }
    func show(_ snapshot: TaskbarSnapshot) {
        log("Snapshot: \(snapshot.buttons.count) buttons, active PID: \(snapshot.activeInstance?.pid.description ?? "none")")
        for button in snapshot.buttons {
            log("\(button.pinID == nil ? "TEMP" : "PIN") \(button.isActive ? "ACTIVE" : "") \(button.tooltip) — PID \(button.instance?.id.pid.description ?? "idle") — \(button.availability.rawValue)")
        }
    }
    func savePins() async {
        do { try await pinStore.save(coordinator.pins.map(\.pin)); log("Pins saved atomically") }
        catch { log("Pin save failed; previous disk state preserved: \(error)") }
    }
    func choosePin(relink: UUID? = nil) {
        guard storageReady else { log("Pin storage is unavailable or still loading"); return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                // Bundle metadata and bookmark creation belong to the storage actor.
                let resolved = await self.pinStore.prepare(url: url)
                guard let resolved else { self.log("Choose a readable application bundle"); return }
                if let relink { _ = self.coordinator.relink(relink, to: resolved) }
                else { _ = self.coordinator.add(resolved) }
                await self.savePins()
            }
        }
    }
    @objc func pinApp() { choosePin() }
    @objc func relinkLast() { if let id = coordinator.pins.last?.pin.id { choosePin(relink: id) } }
    @objc func unpinLast() {
        guard storageReady, let id = coordinator.pins.last?.pin.id else { return }
        coordinator.remove(id); Task { await savePins() }
    }
    @objc func moveLast() {
        guard storageReady, let id = coordinator.pins.last?.pin.id else { return }
        coordinator.move(id, to: 0); Task { await savePins() }
    }
    @objc func launchApp() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
            Task { @MainActor in
                self.log("Waiting for a new actual GUI PID: \(url.path)")
                switch await self.launcher.launch(AppDefinition(url: url, bundleID: bundleID)) {
                case .success(let instance): self.selected = instance; self.log("SUCCESS PID \(instance.id.pid)")
                case .accessorySuccess(let pid): self.log("SUCCESS menu-bar app PID \(pid); not taskbar-managed")
                case .error(let message): self.log("ERROR \(message)")
                case .unconfirmed(let message): self.log("UNCONFIRMED \(message)")
                }
            }
        }
    }
    @objc func activate() {
        guard let selected else { log("Launch an application to select its PID"); return }
        log("Activation PID \(selected.id.pid): \(monitor.activate(selected.id))")
    }
    @objc func windows() {
        guard let selected else { log("Launch an application to select its PID"); return }
        Task { @MainActor in
            switch await accessibility.windows(for: selected.id) {
            case .unavailable(let message): _ = monitor.activate(selected.id); log(message)
            case .windows(let windows):
                log("PID \(selected.id.pid): \(windows.count) standard AX windows")
                for window in windows { log(window.title) }
                let menu = NSMenu()
                for window in windows {
                    let item = NSMenuItem(title: window.title + (window.isMinimized ? " (minimized)" : ""), action: #selector(selectWindow(_:)), keyEquivalent: "")
                    item.target = self; item.representedObject = window
                    menu.addItem(item)
                }
                if !windows.isEmpty { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }

            }
        }
    }
    @objc func selectWindow(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? WindowReference else { return }
        Task { log((await accessibility.select(window)).message) }
    }
    @objc func toggleWindow() {
        guard let selected else { log("Launch an application to select its PID"); return }
        // The regular diagnostic window itself takes focus on click. This explicit
        // test control exercises the selected instance's focused-window toggle.
        Task { log((await accessibility.switchTo(selected.id, minimizeIfActive: true, isActive: true)).message) }
    }
    @objc func permissionStatus() { log(permissions.status.explanation) }
    @objc func permissionSettings() { permissions.openSettingsFromUserAction() }
    @objc func permission() { log("Window control needs Accessibility. Grant WMac! access in System Settings; process functions work without it."); permissions.requestAccessFromUserAction() }
    func applicationWillTerminate(_ notification: Notification) { monitor.stop() }
}
let app = NSApplication.shared
let delegate: any NSApplicationDelegate = CommandLine.arguments.contains("--diagnostics") ? DiagnosticDelegate() : TaskbarDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
