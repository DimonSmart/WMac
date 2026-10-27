import AppKit

func tr(_ en: String, _ ru: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("ru") == true ? ru : en
}

@MainActor final class TaskbarDelegate: NSObject, NSApplicationDelegate {
    let monitor = ProcessMonitor()
    let coordinator = TaskbarCoordinator()
    let pins = PinStore()
    let catalog = ApplicationCatalog()
    lazy var pinMutations = PinMutations(coordinator: coordinator, store: pins)
    private lazy var applicationSearch = ApplicationSearchController(runtime: self)
    let accessibility = AccessibilityService()
    let permissions = AccessibilityPermissionService()
    lazy var launcher = LaunchService(monitor: monitor)
    lazy var displays = DisplayCoordinator(runtime: self)
    let settings = SettingsController()
    let dockVisibility = SystemDockVisibilityService()
    private var dockAttempted = false
    lazy var settingsWindow = SettingsWindowController(runtime: self)
    var preferences: PanelPreferences { PanelPreferences(middleClickNewInstance: settings.value.middleClick) }
    private var status: NSStatusItem!
    private var tokens: [NSObjectProtocol] = []
    private var clock: Timer?
    private var pending: [AppDefinition: Int] = [:]
    private var message = ""
    private var detail = ""
    private var permissionExplained = false
    private var infoWindow: NSWindow?
    private let icons = PanelIcons()
    private var images: [AppDefinition: NSImage] = [:]
    private var loading = Set<AppDefinition>()
    private var windowTitles: [InstanceID: String] = [:]
    private var titleRequest: (InstanceID, Date)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        dockVisibility.recoverAtLaunch()
        dockVisibility.changed = { [weak self] in
            self?.settingsWindow.refresh()
            self?.refreshMenus()
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.title = "W"
        status.button?.toolTip = "WMac!"
        status.button?.image = NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled", accessibilityDescription: "WMac!")
        status.menu = controlsMenu()
        let main = NSMenu(); let applicationItem = NSMenuItem(title: "WMac!", action: nil, keyEquivalent: "")
        applicationItem.submenu = controlsMenu(); main.addItem(applicationItem); NSApp.mainMenu = main
        monitor.changed = { [weak self] values in
            guard let self else { return }
            coordinator.apply(values, active: monitor.activeInstance)
        }
        coordinator.changed = { [weak self] _ in self?.render() }
        displays.reconcile()
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displays.reconcile() }
        })
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.render() } }
        monitor.refresh()
        pinMutations.validate = { [weak self] in self?.valid($0) ?? false }
        pinMutations.changed = { [weak self] in
            guard let self else { return }
            if let failure = pinMutations.failure {
                notify(tr("Pins could not be saved or loaded — Retry pins in WMac menu", "Не удалось сохранить или загрузить закрепления — повторите в меню WMac"), failure + tr("\nThe original file is preserved. Correct access or restore a valid pins.json, then Retry pins.", "\nИсходный файл сохранён. Исправьте доступ или восстановите pins.json и повторите."))
            } else { notify(tr("Pins updated", "Закрепления обновлены")) }
            settingsWindow.refresh()
        }
        settings.changed = { [weak self] in
            guard let self else { return }
            coordinator.setExclusions(Set(settings.value.exclusions)); displays.reconcile()
            synchronizeDockVisibility()
            settingsWindow.refresh()
            if let error = settings.failure { notify(tr("Settings recovery needed", "Нужно восстановить настройки"), error) }
            if settings.ready && !settings.value.dockGuidanceSeen {
                settings.edit { $0.dockGuidanceSeen = true }
                instructions()
            }
        }
        settings.load()
        pinMutations.load()
        if CommandLine.arguments.contains("--settings") { showSettings() }
    }
    func render() {
        let snapshot = coordinator.snapshot
        let live = Set(snapshot.buttons.compactMap { $0.instance?.id })
        windowTitles = windowTitles.filter { live.contains($0.key) }
        if accessibility.trusted, let active = snapshot.activeInstance,
           titleRequest?.0 != active || Date().timeIntervalSince(titleRequest?.1 ?? .distantPast) > 10 {
            titleRequest = (active, Date())
            Task {
                if case .windows(let values) = await accessibility.windows(for: active),
                   let title = values.first(where: \.isFocused)?.title, monitor.running(active) != nil {
                    windowTitles[active] = title; displays.render(coordinator.snapshot)
                }
            }
        }
        let definitions = Set(coordinator.snapshot.buttons.compactMap(\.application))
        images = images.filter { definitions.contains($0.key) }
        for definition in definitions where images[definition] == nil && !loading.contains(definition) {
            loading.insert(definition)
            Task {
                let data = await icons.icon(definition)
                loading.remove(definition)
                if let data, definitions.contains(definition) { let image = NSImage(data: data); image?.size = NSSize(width: 28, height: 28); images[definition] = image }
                displays.render(coordinator.snapshot)
            }
        }
        displays.render(coordinator.snapshot)
    }
    func image(_ definition: AppDefinition?) -> NSImage? { definition.flatMap { images[$0] } ?? NSImage(named: NSImage.applicationIconName) }
    func windowTitle(_ id: InstanceID?) -> String? { id.flatMap { windowTitles[$0] } }
    func pendingCount(_ definition: AppDefinition?) -> Int { definition.flatMap { pending[$0] } ?? 0 }
    func valid(_ capture: ButtonCapture) -> Bool {
        guard capture.matches(coordinator.snapshot) else { return false }
        return capture.instance.map { monitor.running($0) != nil } ?? true
    }
    func click(_ capture: ButtonCapture, new: Bool) {
        guard valid(capture) else { notify(tr("This instance is no longer available", "Экземпляр больше недоступен")); return }
        if new || capture.instance == nil { launch(capture, independent: new); return }
        guard let id = capture.instance else { return }
        explainPermission()
        Task {
            guard valid(capture) else { return }
            let result = await accessibility.switchTo(id, minimizeIfActive: true, isActive: coordinator.snapshot.activeInstance == id && NSWorkspace.shared.frontmostApplication?.processIdentifier == id.pid)
            if result.outcome == .activatedOnly || result.outcome == .unavailable {
                notify(tr("Window control limited — process switching remains available", "Управление окнами ограничено — переключение процесса доступно"), result.message)
            }
        }
    }
    private func launch(_ capture: ButtonCapture, independent: Bool) {
        guard valid(capture), let definition = capture.application else { notify(tr("Application path unavailable", "Путь приложения недоступен")); return }
        launch(definition, independent: independent)
    }
    func launch(_ definition: AppDefinition, independent: Bool = false) {
        pending[definition, default: 0] += 1; render()
        Task {
            let result = independent ? await launcher.launch(definition) : await launcher.open(definition)
            pending[definition, default: 1] -= 1
            switch result {
            case .success: notify(tr("Launch confirmed", "Запуск подтверждён"))
            case .error(let reason): notify(tr("Launch error", "Ошибка запуска"), reason)
            case .unconfirmed(let reason): notify(tr("Launch unconfirmed", "Не удалось подтвердить запуск"), reason)
            }
            monitor.refresh(); render()
        }
    }
    func showApplications(from button: NSButton) { applicationSearch.show(from: button) }
    func pinApplication(_ application: CatalogApplication) {
        pinMutations.submit(.add(application.definition, application.name))
    }
    func dropApplications(_ urls: [URL]) { pinMutations.submit(.drop(urls)) }
    func movePin(_ id: UUID, to index: Int) { pinMutations.submit(.move(id, index)) }
    @objc private func retryPins() { pinMutations.retry() }
    private func chooseReplacement(_ capture: ButtonCapture) {
        let picker = NSOpenPanel()
        picker.title = tr("Choose replacement application", "Выберите новое расположение приложения")
        picker.prompt = tr("Relink", "Связать"); picker.canChooseDirectories = false
        picker.canChooseFiles = true; picker.allowsMultipleSelection = false; picker.allowedContentTypes = [.applicationBundle]
        NSApp.activate()
        if picker.runModal() == .OK, let url = picker.url { pinMutations.submit(.relink(capture, url)) }
    }

    func notify(_ text: String, _ details: String = "") {
        message = text; detail = details
        status.button?.toolTip = text + (details.isEmpty ? "" : "\n" + details)
        refreshMenus(); render()
    }
    private func explainPermission() {
        guard !permissions.trusted, !permissionExplained else { return }
        permissionExplained = true
        notify(tr("Window control needs Accessibility; enable it from the WMac menu", "Для управления окнами включите Универсальный доступ в меню WMac"))
        // Permission request follows this explicit user window-control action only.
        permissions.requestAccessFromUserAction()
    }
    func controlsMenu() -> NSMenu {
        let menu = NSMenu(title: "WMac!")
        func item(_ en: String, _ ru: String, _ selector: Selector, key: String = "") {
            let value = NSMenuItem(title: tr(en, ru), action: selector, keyEquivalent: key); value.target = self; menu.addItem(value)
        }
        item(displays.hidden ? "Show taskbars" : "Hide taskbars", displays.hidden ? "Показать панели" : "Скрыть панели", #selector(togglePanels))
        if dockVisibility.needsRecovery {
            item("Restore system Dock", "Восстановить системный Dock", #selector(restoreSystemDock))
        }
        if pinMutations.failure != nil { item("Retry pins", "Повторить загрузку/сохранение закреплений", #selector(retryPins)) }
        let pinMenu = NSMenu(title: tr("Pinned applications", "Закреплённые приложения"))
        for button in coordinator.snapshot.buttons where button.pinID != nil {
            let entry = NSMenuItem(title: button.name, action: nil, keyEquivalent: "")
            entry.submenu = contextMenu(ButtonCapture(button)); pinMenu.addItem(entry)
        }
        let pinEntry = NSMenuItem(title: pinMenu.title, action: nil, keyEquivalent: "")
        pinEntry.submenu = pinMenu; menu.addItem(pinEntry)
        item("Settings…", "Настройки…", #selector(showSettings), key: ",")
        item("About WMac!", "О WMac!", #selector(about))
        item("Instructions / Dock coexistence", "Инструкция / системный Dock", #selector(instructions))
        item(permissions.trusted ? "Accessibility: enabled" : "Accessibility: limited", permissions.trusted ? "Универсальный доступ: включён" : "Универсальный доступ: ограничен", #selector(permissionStatus))
        item("Enable Accessibility…", "Включить Универсальный доступ…", #selector(requestPermission))
        item("Accessibility settings…", "Настройки Универсального доступа…", #selector(permissionSettings))
        item("Dock settings…", "Настройки Dock…", #selector(dockSettings))
        if !message.isEmpty { menu.addItem(.separator()); item(message + "…", message + "…", #selector(showDetails)) }
        menu.addItem(.separator()); item("Quit WMac!", "Выйти из WMac!", #selector(quit), key: "q")
        return menu
    }
    private func refreshMenus() {
        status.menu = controlsMenu(); NSApp.mainMenu?.items.first?.submenu = controlsMenu()
    }
    private func synchronizeDockVisibility() {
        guard settings.ready else { return }
        if !settings.value.hideSystemDock || displays.hidden {
            if dockVisibility.needsRecovery { dockVisibility.restore() }
            dockAttempted = false
        } else if !dockAttempted {
            dockAttempted = true
            dockVisibility.enable(panelsReady: displays.hasUsablePanels)
        }
    }
    @objc func restoreSystemDock() {
        dockVisibility.restore()
        dockAttempted = false
        if settings.ready { settings.edit { $0.hideSystemDock = false } }
        refreshMenus()
        settingsWindow.refresh()
    }
    @objc func togglePanels() {
        displays.hidden.toggle()
        displays.reconcile()
        synchronizeDockVisibility()
        refreshMenus()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        displays.hidden = false
        displays.reconcile()
        synchronizeDockVisibility()
        refreshMenus()
        return false
    }
    @objc func showSettings() { settingsWindow.show() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func about() { showInfo("WMac!", tr("Native process taskbar. Local persistent settings. Ad-hoc signed DMG; macOS may require first-launch approval.", "Нативная панель процессов. Локальные настройки сохраняются. DMG с ad-hoc подписью; macOS может запросить подтверждение первого запуска.")) }
    @objc func instructions() { showInfo(tr("Instructions", "Инструкция"), tr("Click an instance to switch. Shift-click or middle-click requests a new independent process. Right-click for windows and process actions. Use Tab and Space for buttons, Control-click or Shift-F10 for menus.\n\nWMac coexists with the system Dock. You may enable Dock auto-hide or move it to a side in System Settings → Desktop & Dock. WMac can temporarily hide Dock with explicit consent in General settings; it restores the original preferences when the mode is disabled or WMac quits. It never reserves screen space. Hide panels from the menu bar if they interfere. Fullscreen and Spaces behavior needs verification on your display setup.", "Нажмите на экземпляр для переключения. Shift-клик или средний клик запрашивает новый процесс. Правый клик открывает окна и действия. Tab и пробел управляют кнопками, Control-клик или Shift-F10 — меню.\n\nСистемный Dock остаётся доступен. Автоскрытие или расположение сбоку можно включить в Системных настройках → Рабочий стол и Dock. WMac может временно скрывать Dock по вашему выбору в разделе «Общие», восстанавливая прежние параметры при выключении режима или выходе. Экранное пространство не резервируется. При необходимости скройте панели из строки меню. Полноэкранный режим и Spaces требуют проверки на вашем оборудовании.")) }
    @objc func permissionStatus() { showInfo(tr("Accessibility", "Универсальный доступ"), tr(permissions.status.explanation, permissions.trusted ? "Доступ включён. Управление отдельными окнами зависит от приложения." : "Для выбора, восстановления и сворачивания окон нужен Универсальный доступ. Переключение процессов, запуск и завершение доступны без него.")) }
    @objc func requestPermission() { permissionExplained = true; permissionStatus(); permissions.requestAccessFromUserAction() }
    @objc func permissionSettings() { permissions.openSettingsFromUserAction() }
    @objc func dockSettings() { if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") { NSWorkspace.shared.open(url) } }
    @objc func showDetails() { showInfo(message, detail.isEmpty ? message : detail) }
    private func showInfo(_ title: String, _ text: String) {
        let window = NSWindow(contentRect: NSRect(x: 260, y: 260, width: 540, height: 310), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 500, height: 270)); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let view = NSTextView(frame: scroll.bounds); view.string = text; view.isEditable = false; view.font = .systemFont(ofSize: 15); view.textContainerInset = NSSize(width: 8, height: 8); view.autoresizingMask = [.width]
        scroll.documentView = view; window.contentView?.addSubview(scroll); infoWindow = window
        NSApp.activate(); window.makeKeyAndOrderFront(nil)
    }
    func contextMenu(_ capture: ButtonCapture) -> NSMenu {
        let menu = NSMenu()
        func action(_ en: String, _ ru: String, _ command: String, window: WindowReference? = nil) {
            let item = NSMenuItem(title: tr(en, ru), action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = MenuCommand(capture: capture, action: command, window: window); menu.addItem(item)
        }
        action(capture.instance == nil ? "Open" : "Switch", capture.instance == nil ? "Открыть" : "Переключиться", "switch")
        action("New instance", "Новый экземпляр", "new")
        if let id = capture.instance {
            let windows = NSMenu(title: tr("Windows", "Окна"))
            let placeholder = windows.addItem(withTitle: tr("Loading…", "Загрузка…"), action: nil, keyEquivalent: ""); placeholder.isEnabled = false
            let parent = NSMenuItem(title: windows.title, action: nil, keyEquivalent: ""); parent.submenu = windows; menu.addItem(parent)
            Task {
                let result = await accessibility.windows(for: id)
                windows.removeAllItems()
                guard valid(capture) else { windows.addItem(withTitle: tr("Instance ended", "Экземпляр завершён"), action: nil, keyEquivalent: ""); return }
                switch result {
                case .unavailable(let reason):
                    let item = windows.addItem(withTitle: tr("Accessibility unavailable", "Универсальный доступ недоступен"), action: nil, keyEquivalent: ""); item.toolTip = reason
                case .windows(let values):
                    if values.isEmpty { windows.addItem(withTitle: tr("No manageable windows", "Нет управляемых окон"), action: nil, keyEquivalent: "") }
                    for value in values {
                        let item = NSMenuItem(title: value.title, action: #selector(menuAction(_:)), keyEquivalent: ""); item.target = self
                        item.state = value.isFocused ? .on : .off; item.representedObject = MenuCommand(capture: capture, action: "window", window: value); windows.addItem(item)
                    }
                }
            }
            action("Hide", "Скрыть", "hide"); action("Terminate this instance", "Завершить этот экземпляр", "terminate")
            action("Force terminate…", "Завершить принудительно…", "force")
        }
        action("Reveal in Finder", "Показать в Finder", "reveal")
        if case .pin(let id) = capture.button {
            action("Unpin", "Открепить", "unpin")
            if let index = coordinator.pins.firstIndex(where: { $0.pin.id == id }) {
                if index > 0 { action("Move pin left", "Переместить закрепление влево", "left") }
                if index + 1 < coordinator.pins.count { action("Move pin right", "Переместить закрепление вправо", "right") }
                if coordinator.pins[index].availability == .missing { action("Application not found — choose replacement…", "Приложение не найдено — выбрать новый путь…", "relink") }
            }
        } else if capture.application != nil { action("Pin", "Закрепить", "pin") }
        action("PID / path information", "Сведения: PID / путь", "info")
        return menu
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? MenuCommand, valid(command.capture) else { notify(tr("Stale action rejected", "Устаревшее действие отклонено")); return }
        let capture = command.capture
        switch command.action {
        case "pin":
            pinMutations.submit(.pin(capture))
        case "unpin": pinMutations.submit(.remove(capture))
        case "left", "right":
            if case .pin(let id) = capture.button, let index = coordinator.pins.firstIndex(where: { $0.pin.id == id }) { movePin(id, to: index + (command.action == "left" ? -1 : 1)) }
        case "relink": chooseReplacement(capture)
        case "switch": click(capture, new: false)
        case "new": click(capture, new: true)
        case "window":
            explainPermission()
            if let window = command.window { Task { guard valid(capture) else { return }; let result = await accessibility.select(window); if result.outcome == .activatedOnly || result.outcome == .unavailable { notify(tr("Window action limited", "Действие окна ограничено"), result.message) } } }
        case "hide": if let id = capture.instance { _ = monitor.running(id)?.hide() }
        case "terminate": if let id = capture.instance { _ = monitor.terminate(id) }
        case "force":
            let alert = NSAlert(); alert.messageText = tr("Force terminate this instance?", "Принудительно завершить этот экземпляр?"); alert.informativeText = tr("Unsaved work may be lost. PID: ", "Несохранённые данные могут быть потеряны. PID: ") + (capture.instance?.pid.description ?? "")
            alert.addButton(withTitle: tr("Cancel", "Отмена")); alert.addButton(withTitle: tr("Force terminate", "Завершить")); NSApp.activate()
            if alert.runModal() == .alertSecondButtonReturn, valid(capture), let id = capture.instance { _ = monitor.running(id)?.forceTerminate() }
        case "reveal": if let url = capture.application?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case "info": showInfo("WMac!", "PID: \(capture.instance?.pid.description ?? "—")\n\(capture.application?.url.path ?? "—")")
        default: break
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await settings.settled()
            await pinMutations.wait()
            dockVisibility.restore()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { dockVisibility.restore(); clock?.invalidate(); monitor.stop(); displays.close(); for token in tokens { NotificationCenter.default.removeObserver(token) } }
}
private struct MenuCommand { let capture: ButtonCapture; let action: String; let window: WindowReference? }

/// Bounded, background icon rasterization. No system icon/filesystem calls in refresh rendering.
private actor PanelIcons {
    func icon(_ definition: AppDefinition) -> Data? {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSWorkspace.shared.icon(forFile: definition.url.path).draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState(); return bitmap.representation(using: .png, properties: [:])
    }
}

@MainActor final class DisplayCoordinator {
    unowned let runtime: TaskbarDelegate
    var hidden = false
    private var panels: [UInt32: TaskbarPanel] = [:]
    var hasUsablePanels: Bool { !hidden && !panels.isEmpty }
    init(runtime: TaskbarDelegate) { self.runtime = runtime }
    func reconcile() {
        let screens = NSScreen.screens.filter { runtime.settings.value.allDisplays || ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() }.compactMap { screen -> (DisplayLayout, NSScreen)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (DisplayLayout(id: id.uint32Value, frame: screen.frame), screen)
        }
        let delta = DisplayLayout.reconcile(owned: Set(panels.keys), screens: screens.map(\.0))
        for id in delta.removed { panels.removeValue(forKey: id)?.close() }
        for (layout, _) in screens {
            let panel = panels[layout.id] ?? TaskbarPanel(runtime: runtime)
            panels[layout.id] = panel
            var frame = layout.panelFrame(height: runtime.settings.value.height)
            // Explicit developer harness for real overflow testing without fake buttons.
            if let index = CommandLine.arguments.firstIndex(of: "--panel-test-width"),
               CommandLine.arguments.indices.contains(index + 1),
               let width = Double(CommandLine.arguments[index + 1]), width >= 400 {
                frame.size.width = min(frame.width, width); frame.origin.x = layout.frame.midX - frame.width / 2
            }
            panel.appearance = runtime.settings.value.theme == .system ? nil : NSAppearance(named: runtime.settings.value.theme == .dark ? .darkAqua : .aqua)
            panel.bar.applyOpacity(runtime.settings.value.opacity)
            panel.setFrame(frame, display: true)
            if hidden { panel.orderOut(nil) } else { panel.orderFront(nil) }
        }
        render(runtime.coordinator.snapshot)
    }
    func render(_ snapshot: TaskbarSnapshot) { for panel in panels.values { panel.bar.render(snapshot) } }
    func close() { for panel in panels.values { panel.close() }; panels.removeAll() }
}
@MainActor private final class TaskbarPanel: NSPanel {
    let bar: TaskbarView
    init(runtime: TaskbarDelegate) {
        bar = TaskbarView(runtime: runtime)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; isFloatingPanel = true; level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenNone, .stationary, .ignoresCycle]
        hidesOnDeactivate = false; isOpaque = false; backgroundColor = .clear; hasShadow = true
        contentView = bar; setAccessibilityLabel("WMac!")
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
@MainActor private final class TaskbarView: NSView {
    unowned let runtime: TaskbarDelegate
    let scroll = NSScrollView()
    let content = NSView()
    let clock = NSTextField(labelWithString: "")
    let applications = NSButton(title: "", target: nil, action: nil)
    let controls = NSButton(title: "W", target: nil, action: nil)
    let previous = NSButton(title: "‹", target: nil, action: nil)
    let next = NSButton(title: "›", target: nil, action: nil)
    private let backdrop = NSVisualEffectView()
    private var buttons: [TaskbarButtonID: ProcessButton] = [:]
    func applyOpacity(_ opacity: Double) {
        // Tint the backing material only; text, icons and hit targets stay opaque.
        backdrop.alphaValue = opacity
    }
    init(runtime: TaskbarDelegate) {
        self.runtime = runtime; super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, pinDragType])
        backdrop.frame = bounds; backdrop.autoresizingMask = [.width, .height]
        backdrop.material = .hudWindow; backdrop.blendingMode = .behindWindow; backdrop.state = .active
        addSubview(backdrop)
        wantsLayer = true; layer?.cornerRadius = 12; layer?.masksToBounds = true
        scroll.drawsBackground = false; scroll.documentView = content; scroll.hasHorizontalScroller = false; scroll.horizontalScrollElasticity = .allowed
        addSubview(scroll); addSubview(clock)
        for button in [applications, controls, previous, next] { button.bezelStyle = .texturedRounded; button.target = self; addSubview(button) }
        applications.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: tr("Applications", "Приложения"))
        applications.action = #selector(showApplications); applications.toolTip = tr("Applications", "Приложения")
        applications.setAccessibilityLabel(tr("Applications", "Приложения"))
        controls.action = #selector(showControls); controls.setAccessibilityLabel(tr("WMac controls", "Управление WMac"))
        previous.action = #selector(back); previous.setAccessibilityLabel(tr("Scroll applications left", "Прокрутить приложения влево"))
        next.action = #selector(forward); next.setAccessibilityLabel(tr("Scroll applications right", "Прокрутить приложения вправо"))
        clock.alignment = .center; clock.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); clock.maximumNumberOfLines = 2
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); place() }
    func render(_ snapshot: TaskbarSnapshot) {
        let ids = Set(snapshot.buttons.map(\.id))
        for (id, button) in buttons where !ids.contains(id) { button.removeFromSuperview(); buttons[id] = nil }
        for (index, value) in snapshot.buttons.enumerated() {
            let button = buttons[value.id] ?? ProcessButton(runtime: runtime)
            buttons[value.id] = button; if button.superview == nil { content.addSubview(button) }
            button.update(value)
            let targetHeight = max(36, bounds.height - 8)
            button.frame = NSRect(x: CGFloat(index) * 44, y: max(0, (bounds.height - 4 - targetHeight) / 2), width: 40, height: targetHeight)
        }
        content.setFrameSize(NSSize(width: CGFloat(snapshot.buttons.count) * 44, height: max(36, bounds.height - 4)))
        let format = DateFormatter(); format.dateStyle = .short; format.timeStyle = .short
        clock.stringValue = format.string(from: Date()).replacingOccurrences(of: ", ", with: "\n")
        place()
    }
    private func place() {
        let regions = PanelRegions(width: bounds.width, contentWidth: content.frame.width, height: bounds.height)
        applications.frame = regions.launcher
        controls.frame = regions.controls; clock.frame = regions.clock
        scroll.frame = regions.apps; previous.frame = regions.previous; next.frame = regions.next
        previous.isHidden = !regions.overflow; next.isHidden = !regions.overflow

    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }
    private func dragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let source = sender.draggingSource as? ProcessButton, source.runtime === runtime,
           let id = source.draggedPin, runtime.coordinator.pins.contains(where: { $0.pin.id == id }) { return .move }
        return droppedURLs(sender).isEmpty ? [] : .copy
    }
    private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return !urls.isEmpty && urls.allSatisfy { $0.isFileURL && $0.pathExtension.lowercased() == "app" } ? urls : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if dragOperation(sender) == .move, let source = sender.draggingSource as? ProcessButton, let id = source.draggedPin {
            let point = content.convert(sender.draggingLocation, from: nil)
            runtime.movePin(id, to: Int(max(0, point.x) / 44)); return true
        }
        let urls = droppedURLs(sender)
        guard !urls.isEmpty else { return false }
        runtime.dropApplications(urls); return true
    }
    @objc private func back() { move(-176) }
    @objc private func forward() { move(176) }
    private func move(_ distance: CGFloat) {
        // Immediate scrolling respects Reduce Motion without an animation branch.
        let x = min(max(0, content.frame.width - scroll.contentSize.width), max(0, scroll.contentView.bounds.minX + distance))
        scroll.contentView.scroll(to: NSPoint(x: x, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
    }
    @objc private func showApplications() { runtime.showApplications(from: applications) }
    @objc private func showControls() { runtime.controlsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: controls.bounds.maxY), in: controls) }
}
private let pinDragType = NSPasteboard.PasteboardType("app.wmac.pin")

@MainActor private final class ProcessButton: NSButton, NSDraggingSource {
    unowned let runtime: TaskbarDelegate
    private var capture: ButtonCapture?
    private(set) var draggedPin: UUID?
    init(runtime: TaskbarDelegate) {
        self.runtime = runtime; super.init(frame: .zero)
        target = self; action = #selector(pressed); imagePosition = .imageOnly; imageScaling = .scaleProportionallyDown
        bezelStyle = .regularSquare; isBordered = false; wantsLayer = true; layer?.cornerRadius = 7
        setAccessibilityRole(.button)
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: tr("Show actions", "Показать действия"), handler: { [weak self] in self?.accessibilityPerformShowMenu() ?? false })])
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ value: TaskbarButton) {
        capture = ButtonCapture(value); image = runtime.image(value.application)
        let pending = runtime.pendingCount(value.application)
        let label = (value.availability == .missing ? tr("Application not found: ", "Приложение не найдено: ") : "") + value.name + (value.ordinal.map { tr(" — instance \($0)", " — экземпляр \($0)") } ?? "") + (value.instance.map { " — PID \($0.id.pid)" } ?? "")
        toolTip = label + (runtime.windowTitle(value.instance?.id).map { " — " + $0 } ?? "") + (pending > 0 ? tr(" — pending: \(pending)", " — ожидание: \(pending)") : "")
        setAccessibilityLabel(label); setAccessibilityHelp(toolTip)
        setAccessibilityValue(value.isActive ? tr("Active", "Активен") : (pending > 0 ? tr("Pending", "Ожидание") : ""))
        layer?.backgroundColor = (value.isActive ? NSColor.controlAccentColor.withAlphaComponent(0.30) : NSColor.clear).cgColor
        title = value.instance != nil ? "•" : ""; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let capture {
            let pending = runtime.pendingCount(capture.application)
            if capture.instance != nil || pending > 0 {
                (pending > 0 ? NSColor.systemOrange : NSColor.controlAccentColor).setFill()
                NSBezierPath(roundedRect: NSRect(x: 15, y: isFlipped ? bounds.maxY - 4 : 1, width: 10, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }
    @objc private func pressed() {
        guard let capture else { return }
        let event = NSApp.currentEvent
        if event?.buttonNumber == 2 && !runtime.preferences.middleClickNewInstance { return }
        runtime.click(capture, new: event?.modifierFlags.contains(.shift) == true || event?.buttonNumber == 2)
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        // Track explicitly so NSButton never dispatches a press after starting a drag.
        guard let captured = capture, let window else { return }
        var dragEvent: NSEvent?
        var released = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { released = true; break }
            if hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y) >= 5 { dragEvent = next; break }
        }
        if let dragEvent {
            guard case .pin(let id) = captured.button, runtime.valid(captured) else { return }
            draggedPin = id
            let writer = NSPasteboardItem(); writer.setString(id.uuidString, forType: pinDragType)
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [item], event: dragEvent, source: self)
        } else if released { runtime.click(captured, new: event.modifierFlags.contains(.shift)) }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { draggedPin = nil }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 109 && event.modifierFlags.contains(.shift) { _ = accessibilityPerformShowMenu() }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformShowMenu() -> Bool {
        guard let capture else { return false }
        runtime.contextMenu(capture).popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
        return true
    }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2, runtime.preferences.middleClickNewInstance, let capture { runtime.click(capture, new: true) }
    }
    override func otherMouseUp(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { capture.map { runtime.contextMenu($0) } }
    override func rightMouseDown(with event: NSEvent) { if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) } }
}

/// One transient native popover can be anchored to any display's launcher.
@MainActor private final class ApplicationSearchController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    unowned let runtime: TaskbarDelegate
    private let popover = NSPopover()
    private let search = NSSearchField()
    private let table = ApplicationResultsTable()
    private let scroll = NSScrollView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let refresh = NSButton(title: tr("Refresh", "Обновить"), target: nil, action: nil)
    private var state = ApplicationSearchState()
    private var icons: [AppDefinition: NSImage] = [:]
    private var refreshTask: Task<Void, Never>?
    private var updating = false

    init(runtime: TaskbarDelegate) {
        self.runtime = runtime
        super.init(nibName: nil, bundle: nil)
        popover.behavior = .transient; popover.contentViewController = self
        runtime.catalog.changed = { [weak self] values in self?.receive(values) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 430))
        search.frame = NSRect(x: 12, y: 382, width: 300, height: 36)
        search.placeholderString = tr("Search applications", "Поиск приложений")
        search.setAccessibilityLabel(tr("Search applications", "Поиск приложений"))
        search.delegate = self; search.sendsSearchStringImmediately = true
        refresh.frame = NSRect(x: 316, y: 382, width: 92, height: 36)
        refresh.target = self; refresh.action = #selector(reloadCatalog)
        refresh.setAccessibilityLabel(tr("Refresh applications", "Обновить приложения"))
        scroll.frame = NSRect(x: 12, y: 46, width: 396, height: 328)
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application"))
        column.width = 376; table.addTableColumn(column); table.headerView = nil
        table.rowHeight = 48; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.delegate = self; table.dataSource = self; table.target = self; table.action = #selector(activateClicked)
        table.setAccessibilityLabel(tr("Applications", "Приложения"))
        table.activateSelection = { [weak self] in self?.activateSelection() }
        table.dismiss = { [weak self] in self?.popover.performClose(nil) }
        table.openMenu = { [weak self] in self?.showSelectionMenu() }
        table.resultMenu = { [weak self] row in self?.contextMenu(row: row) }
        scroll.documentView = table
        stateLabel.frame = NSRect(x: 16, y: 8, width: 388, height: 32)
        stateLabel.font = .systemFont(ofSize: 12); stateLabel.textColor = .secondaryLabelColor
        stateLabel.maximumNumberOfLines = 2
        for subview in [search, refresh, scroll, stateLabel] { view.addSubview(subview) }
        search.nextKeyView = table; table.nextKeyView = refresh; refresh.nextKeyView = search
    }
    func show(from button: NSButton) {
        if popover.isShown { popover.performClose(nil); return }
        loadViewIfNeeded()
        state.query = ""; search.stringValue = ""; receive(runtime.catalog.snapshot)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        NSApp.activate(); view.window?.makeKey(); view.window?.makeFirstResponder(search)
        reloadCatalog()
    }
    @objc private func reloadCatalog() {
        refreshTask?.cancel(); state.beginRefresh(); update()
        let urls = runtime.monitor.snapshot.compactMap { $0.definition?.url }
        refreshTask = Task { await runtime.catalog.refresh(supplementalURLs: urls) }
    }
    private func receive(_ applications: [CatalogApplication]) {
        state.receive(applications)
        // Decode catalog's bounded icon payload once per publication, outside row rendering.
        icons = Dictionary(uniqueKeysWithValues: applications.map { ($0.definition, $0.icon) })
        if isViewLoaded { update() }
    }
    private func update() {
        updating = true
        let row = state.results.firstIndex { $0.definition == state.selected }
        table.reloadData()
        table.selectRowIndexes(row.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
        if let row { table.scrollRowToVisible(row) }
        updating = false
        switch state.content {
        case .loading: stateLabel.stringValue = tr("Loading applications…", "Загрузка приложений…")
        case .empty: stateLabel.stringValue = tr("No applications found. Try Refresh.", "Приложения не найдены. Нажмите «Обновить».")
        case .noMatches: stateLabel.stringValue = tr("No matching applications", "Нет подходящих приложений")
        case .results: stateLabel.stringValue = state.isLoading ? tr("Refreshing…", "Обновление…") : tr("Enter to open · Right-click or Shift-F10 to pin", "Enter — открыть · Правый клик или Shift-F10 — закрепить")
        }
        stateLabel.setAccessibilityLabel(stateLabel.stringValue)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { state.results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard state.results.indices.contains(row) else { return nil }
        let application = state.results[row]
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 376, height: 48))
        let image = NSImageView(frame: NSRect(x: 6, y: 8, width: 32, height: 32)); image.image = icons[application.definition]
        let name = NSTextField(labelWithString: application.name); name.frame = NSRect(x: 48, y: 24, width: 320, height: 20)
        let path = NSTextField(labelWithString: application.definition.url.path); path.frame = NSRect(x: 48, y: 5, width: 320, height: 18)
        path.font = .systemFont(ofSize: 10); path.textColor = .secondaryLabelColor; path.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(image); cell.addSubview(name); cell.addSubview(path); cell.textField = name; cell.imageView = image
        cell.toolTip = application.name + "\n" + application.definition.url.path
        cell.setAccessibilityLabel(application.name + " — " + application.definition.url.path)
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if !updating { state.select(row: table.selectedRow) } }
    func controlTextDidChange(_ obj: Notification) { state.query = search.stringValue; update() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): state.move(1); update(); return true
        case #selector(NSResponder.moveUp(_:)): state.move(-1); update(); return true
        case #selector(NSResponder.insertNewline(_:)): activateSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)): popover.performClose(nil); return true
        default: return false
        }
    }
    @objc private func activateClicked() {
        guard table.clickedRow >= 0 else { return }
        state.select(row: table.clickedRow); activateSelection()
    }
    private func activateSelection() {
        guard let application = state.selection else { return }
        popover.performClose(nil)
        runtime.notify(tr("Opening \(application.name)…", "Открытие \(application.name)…"))
        runtime.launch(application.definition)
    }
    private func contextMenu(row: Int) -> NSMenu? {
        guard state.results.indices.contains(row) else { return nil }
        // Freeze the exact definition while a menu is tracking; refresh cannot retarget it.
        let menuSelection = state.results[row]
        let menu = NSMenu()
        let item = NSMenuItem(title: tr("Pin", "Закрепить"), action: #selector(pinSelection), keyEquivalent: "")
        item.target = self; item.representedObject = menuSelection
        menu.addItem(item); return menu
    }
    private func showSelectionMenu() {
        let row = table.selectedRow
        guard let menu = contextMenu(row: row) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 48, y: table.rect(ofRow: row).midY), in: table)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 109 && event.modifierFlags.contains(.shift) { showSelectionMenu() }
        else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { popover.performClose(nil) }
    @objc private func pinSelection(_ sender: NSMenuItem) {
        guard let application = sender.representedObject as? CatalogApplication else { return }
        runtime.pinApplication(application)
    }
}

@MainActor private final class ApplicationResultsTable: NSTableView {
    var activateSelection: (() -> Void)?
    var dismiss: (() -> Void)?
    var openMenu: (() -> Void)?
    var resultMenu: ((Int) -> NSMenu?)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { activateSelection?() }
        else if event.keyCode == 53 { dismiss?() }
        else if event.keyCode == 109 && event.modifierFlags.contains(.shift) { openMenu?() }
        else { super.keyDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { resultMenu?(row(at: convert(event.locationInWindow, from: nil))) }
    override func accessibilityPerformShowMenu() -> Bool { openMenu?(); return selectedRow >= 0 }
}
