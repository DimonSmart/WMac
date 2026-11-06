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
    lazy var previews = WindowPreviewController(runtime: self)
    lazy var windowArrangementShortcuts = WindowArrangementShortcuts(accessibility: accessibility, permissions: permissions)
    private var updateRestartReady = false
    let updates = ApplicationUpdateController()
    let settings = SettingsController()
    let dockVisibility = SystemDockVisibilityService()
    private var dockAttempted = false
    private var dockManuallyRestored = false
    lazy var settingsWindow = SettingsWindowController(runtime: self)
    private lazy var aboutWindow = AboutWindowController()
    var preferences: PanelPreferences { PanelPreferences(middleClickNewInstance: settings.value.middleClick) }
    private var status: NSStatusItem!
    private var tokens: [NSObjectProtocol] = []
    private var clock: Timer?
    private var pending: [AppDefinition: Int] = [:]
    private var reopening = Set<AppDefinition>()
    private var message = ""
    private var detail = ""
    private var permissionExplained = false
    private var permissionNotice: NSPanel?
    private var infoWindow: NSWindow?
    private let icons = PanelIcons()
    private var images: [PanelIconSource: NSImage] = [:]
    private var loading = Set<PanelIconSource>()
    private var windowTitles: [InstanceID: String] = [:]
    private var titleRequest: (InstanceID, Date)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--updated-from-pid"),
           CommandLine.arguments.indices.contains(index + 1),
           let pid = Int32(CommandLine.arguments[index + 1]), pid > 0 {
            // Acknowledge launch to LaunchServices before waiting for the old instance.
            Task {
                let previous = NSRunningApplication(processIdentifier: pid)
                let deadline = Date().addingTimeInterval(30)
                while previous?.isTerminated == false && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if previous?.isTerminated == false { exit(1) }
                finishLaunching()
            }
        } else {
            finishLaunching()
        }
    }
    private func finishLaunching() {
        NSApp.setActivationPolicy(.accessory)
        dockVisibility.recoverAtLaunch()
        dockVisibility.changed = { [weak self] in
            self?.settingsWindow.refresh()
            self?.refreshMenus()
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.title = BuildIdentity.isLocal ? "L" : "W"
        status.button?.toolTip = BuildIdentity.name + " — " + Bundle.main.bundleURL.path
        status.button?.image = NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled", accessibilityDescription: "WMac!")
        NSApp.applicationIconImage = BuildIdentity.icon(
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) })
        status.menu = controlsMenu()
        let main = NSMenu(); let applicationItem = NSMenuItem(title: "WMac!", action: nil, keyEquivalent: "")
        applicationItem.submenu = applicationMenu(); main.addItem(applicationItem); NSApp.mainMenu = main
        monitor.changed = { [weak self] values in
            guard let self else { return }
            coordinator.apply(values, active: monitor.activeInstance)
        }
        coordinator.changed = { [weak self] _ in self?.render() }
        coordinator.discoveredLayout = { [weak self] in self?.pinMutations.synchronizeLayout() }
        displays.reconcile()
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displays.reconcile(); self?.synchronizeDockVisibility() }
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
        windowArrangementShortcuts.changed = { [weak self] in self?.settingsWindow.refresh() }
        windowArrangementShortcuts.notify = { [weak self] title, details in self?.notify(title, details) }
        settings.changed = { [weak self] in
            guard let self else { return }
            displays.reconcile()
            previews.settingsChanged()
            if settings.ready { windowArrangementShortcuts.setEnabled(settings.value.windowArrangementShortcuts) }
            synchronizeDockVisibility()
            settingsWindow.refresh()
            refreshMenus()
            if let error = settings.failure { notify(tr("Settings recovery needed", "Нужно восстановить настройки"), error) }
            if settings.ready && !settings.value.dockGuidanceSeen {
                settings.edit { $0.dockGuidanceSeen = true }
                instructions()
            }
        }
        updates.changed = { [weak self] in
            guard let self else { return }
            if !updates.installing { updateRestartReady = false }
            refreshMenus()
        }
        updates.prepareRestart = { [weak self] in
            guard let self else { return }
            await settings.settled()
            await pinMutations.wait()
            dockVisibility.restore()
            updateRestartReady = true
        }
        updates.start()
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
                if case .windows(let values, _) = await accessibility.windows(for: active),
                   let title = values.first(where: \.isFocused)?.title, monitor.running(active) != nil {
                    windowTitles[active] = title; displays.render(coordinator.snapshot)
                }
            }
        }
        let iconSources = Set(snapshot.buttons.compactMap(PanelIconSource.init))
        images = images.filter { iconSources.contains($0.key) }
        for source in iconSources where images[source] == nil && !loading.contains(source) {
            loading.insert(source)
            Task {
                let data = await icons.icon(source)
                loading.remove(source)
                if let data, coordinator.snapshot.buttons.contains(where: { PanelIconSource($0) == source }) {
                    images[source] = NSImage(data: data)
                }
                displays.render(coordinator.snapshot)
            }
        }
        displays.render(coordinator.snapshot)
        previews.reconcile()
    }
    func image(_ button: TaskbarButton) -> NSImage { PanelIconSource(button).flatMap { images[$0] } ?? PanelIcons.fallback }
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
        let wasActive = coordinator.snapshot.activeInstance == id
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == id.pid
        Task {
            guard valid(capture) else { return }
            let result = await accessibility.switchTo(id, minimizeIfActive: true, isActive: wasActive)
            if result.outcome == .noManageableWindows {
                await requestReopen(capture, instance: id)
            } else if result.outcome == .activatedOnly || result.outcome == .unavailable {
                notify(tr("Window control limited — process switching remains available", "Управление окнами ограничено — переключение процесса доступно"), result.message)
                explainPermission()
            }
        }
    }
    private func requestReopen(_ capture: ButtonCapture, instance: InstanceID) async {
        guard let definition = capture.application else {
            notify(tr("Application path unavailable", "Путь приложения недоступен"))
            return
        }
        let matching = monitor.instances(of: definition)
        guard valid(capture) else { return }
        guard matching.count == 1, matching.first?.id == instance else {
            notify(tr("This instance has no open windows", "У этого экземпляра нет открытых окон"),
                   tr("Several instances are running, so the system could reopen a different PID. WMac kept the exact process active.", "Запущено несколько экземпляров, поэтому система могла бы открыть другой PID. WMac оставил активным выбранный процесс."))
            return
        }
        guard reopening.insert(definition).inserted else { return }
        pending[definition, default: 0] += 1
        render()
        defer {
            pending[definition, default: 1] -= 1
            reopening.remove(definition)
            render()
        }

        switch await launcher.open(definition) {
        case .success(let opened):
            monitor.refresh()
            let deadline = Date().addingTimeInterval(3)
            var windowStateUnavailable = false
            while Date() < deadline {
                guard monitor.running(opened.id) != nil else { break }
                switch await accessibility.windows(for: opened.id) {
                case .windows(let windows, _):
                    windowStateUnavailable = false
                    if !windows.isEmpty { return }
                case .unavailable:
                    windowStateUnavailable = true
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            if monitor.running(opened.id) == nil {
                notify(tr("Application closed before reopening a window", "Приложение завершилось до повторного открытия окна"))
            } else if windowStateUnavailable {
                notify(tr("Reopen request sent", "Запрос на повторное открытие отправлен"),
                       tr("WMac could not verify whether the application opened a window.", "WMac не смог проверить, открыло ли приложение окно."))
            } else {
                notify(tr("Application is running without an open window", "Приложение работает без открытых окон"),
                       tr("The application did not create a window after the reopen request.", "Приложение не создало окно после запроса на повторное открытие."))
            }
        case .accessorySuccess(let pid):
            notify(tr("Menu-bar app is running", "Приложение строки меню запущено"),
                   tr("PID \(pid) is not shown as a taskbar button.", "PID \(pid) не отображается кнопкой на панели."))
        case .error(let reason):
            notify(tr("Could not reopen application", "Не удалось повторно открыть приложение"), reason)
        case .unconfirmed(let reason):
            notify(tr("Reopen request was not confirmed", "Не удалось подтвердить повторное открытие"), reason)
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
            case .accessorySuccess(let pid):
                notify(tr("Launch confirmed", "Запуск подтверждён"),
                       tr("Menu-bar app is running as PID \(pid); it is not shown as a taskbar button.", "Приложение строки меню работает как PID \(pid); оно не отображается кнопкой на панели."))
            case .error(let reason): notify(tr("Launch error", "Ошибка запуска"), reason)
            case .unconfirmed(let reason): notify(tr("Launch unconfirmed", "Не удалось подтвердить запуск"), reason)
            }
            monitor.refresh(); render()
        }
    }
    func showApplications(from button: NSButton) { applicationSearch.show(from: button) }
    func pinApplication(_ application: CatalogApplication) {
        guard !application.isMenuBarOnly else {
            notify(tr("Menu-bar apps cannot be pinned", "Приложения строки меню нельзя закрепить"))
            return
        }
        pinMutations.submit(.add(application.definition, application.name))
    }
    func dropApplications(_ urls: [URL]) { pinMutations.submit(.drop(urls)) }
    func moveButton(_ capture: ButtonCapture, to index: Int) { pinMutations.submit(.reorder(capture, index)) }
    @objc private func retryPins() { pinMutations.retry() }
    func chooseReplacement(_ capture: ButtonCapture) {
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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 190),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = tr("Window control needs permission", "Для управления окнами нужно разрешение")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(wrappingLabelWithString: tr(
            "To minimize and restore windows, allow WMac in System Settings → Privacy & Security → Accessibility. Switching to an application still works without this permission.",
            "Чтобы сворачивать и восстанавливать окна, разрешите WMac доступ в Системных настройках → Конфиденциальность и безопасность → Универсальный доступ. Переключение на приложение работает и без разрешения."))
        text.font = .systemFont(ofSize: 13)
        text.preferredMaxLayoutWidth = 412
        content.addArrangedSubview(text)
        let buttons = NSStackView()
        buttons.spacing = 12
        let configure = NSButton(title: tr("Open Settings…", "Открыть настройки…"),
                                 target: self, action: #selector(configureWindowPermission))
        configure.bezelStyle = .rounded
        let later = NSButton(title: tr("Later", "Позже"), target: self, action: #selector(dismissPermissionNotice))
        later.bezelStyle = .rounded
        later.keyEquivalent = "\u{1b}"
        buttons.addArrangedSubview(configure)
        buttons.addArrangedSubview(later)
        content.addArrangedSubview(buttons)
        if let view = panel.contentView {
            view.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
                content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
                content.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                content.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor, constant: 20),
                content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20)
            ])
        }
        permissionNotice = panel
        panel.center()
        // Keep the selected process active; this explanation never runs a modal loop.
        panel.makeKeyAndOrderFront(nil)
    }
    @objc private func dismissPermissionNotice() { permissionNotice?.close(); permissionNotice = nil }
    @objc private func configureWindowPermission() {
        dismissPermissionNotice()
        permissions.openSettingsFromUserAction()
    }
    private func applicationMenu() -> NSMenu {
        let menu = NSMenu(title: "WMac!")
        func item(_ en: String, _ ru: String, _ selector: Selector, key: String = "") {
            let value = NSMenuItem(title: tr(en, ru), action: selector, keyEquivalent: key)
            value.target = self
            menu.addItem(value)
        }
        item("About WMac!", "О WMac!", #selector(about))
        updates.addCommands(to: menu)
        menu.addItem(.separator())
        item("Settings…", "Настройки…", #selector(showSettings), key: ",")
        item("Help", "Справка", #selector(instructions))
        menu.addItem(.separator())
        addSystemDockCommands(to: menu)
        menu.addItem(.separator())
        item("Quit WMac!", "Выйти из WMac!", #selector(quit), key: "q")
        return menu
    }
    func controlsMenu() -> NSMenu {
        let menu = NSMenu(title: "WMac!")
        func item(_ en: String, _ ru: String, _ selector: Selector, key: String = "") {
            let value = NSMenuItem(title: tr(en, ru), action: selector, keyEquivalent: key)
            value.target = self
            menu.addItem(value)
        }
        item(displays.hidden ? "Show taskbars" : "Hide taskbars", displays.hidden ? "Показать панели" : "Скрыть панели", #selector(togglePanels))
        addSystemDockCommands(to: menu)
        if pinMutations.failure != nil {
            item("Retry pins", "Повторить сохранение закреплений", #selector(retryPins))
        }
        menu.addItem(.separator())
        item("Settings…", "Настройки…", #selector(showSettings), key: ",")
        item("About WMac!", "О WMac!", #selector(about))
        updates.addCommands(to: menu)
        item("Help", "Справка", #selector(instructions))
        menu.addItem(.separator())
        item("Quit WMac!", "Выйти из WMac!", #selector(quit), key: "q")
        return menu
    }
    private func addSystemDockCommands(to menu: NSMenu) {
        let hide = NSMenuItem(title: tr("Hide system Dock", "Скрыть системный Dock"),
                              action: #selector(hideSystemDock), keyEquivalent: "")
        hide.target = self
        hide.isEnabled = settings.ready && displays.hasUsablePanels &&
            !dockVisibility.active && !dockVisibility.needsRecovery
        menu.addItem(hide)

        let restore = NSMenuItem(title: tr("Restore system Dock", "Восстановить системный Dock"),
                                 action: #selector(restoreSystemDock), keyEquivalent: "")
        restore.target = self
        restore.isEnabled = dockVisibility.needsRecovery || (settings.ready && settings.value.hideSystemDock)
        menu.addItem(restore)
    }
    private func refreshMenus() {
        status.menu = controlsMenu()
        NSApp.mainMenu?.items.first?.submenu = applicationMenu()
    }
    private func synchronizeDockVisibility() {
        guard settings.ready else { return }
        if !settings.value.hideSystemDock { dockManuallyRestored = false }
        if dockManuallyRestored || !settings.value.hideSystemDock || displays.hidden {
            if dockVisibility.needsRecovery { dockVisibility.restore() }
            dockAttempted = false
        } else if !dockAttempted && displays.hasUsablePanels {
            dockAttempted = true
            dockVisibility.enable(panelsReady: true)
        }
    }
    @objc func hideSystemDock() {
        guard settings.ready, displays.hasUsablePanels,
              !dockVisibility.active, !dockVisibility.needsRecovery else { return }
        if settings.value.hideSystemDock {
            dockManuallyRestored = false
            dockAttempted = false
            synchronizeDockVisibility()
            refreshMenus()
        } else {
            confirmDockHiding()
        }
    }
    func confirmDockHiding(sheetFor window: NSWindow? = nil, onCancel: (() -> Void)? = nil) {
        guard settings.ready else { onCancel?(); return }
        let alert = NSAlert()
        alert.messageText = tr("Hide system Dock?", "Скрыть системный Dock?")
        alert.informativeText = tr(
            "WMac will change the system Dock's auto-hide preferences. Their original values will be saved and restored when this option is disabled or WMac quits. The Dock will restart to apply the changes.",
            "WMac изменит настройки автоматического скрытия системного Dock. Исходные значения будут сохранены и восстановлены при отключении этой функции или завершении WMac. Для применения настроек системный Dock будет перезапущен.")
        alert.addButton(withTitle: tr("Enable", "Включить"))
        alert.addButton(withTitle: tr("Cancel", "Отмена"))
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.dockManuallyRestored = false
                self.dockAttempted = false
                self.settings.edit { $0.hideSystemDock = true }
            } else { onCancel?() }
        }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: complete)
        } else {
            let wasAccessory = NSApp.activationPolicy() == .accessory
            if wasAccessory { NSApp.setActivationPolicy(.regular) }
            NSApp.activate()
            let response = alert.runModal()
            if wasAccessory { NSApp.setActivationPolicy(.accessory) }
            complete(response)
        }
    }
    @objc func restoreSystemDock() {
        dockManuallyRestored = true
        dockVisibility.restore()
        dockAttempted = false
        if settings.ready { settings.edit { $0.hideSystemDock = false } }
        refreshMenus()
        settingsWindow.refresh()
    }
    @objc func togglePanels() {
        previews.close()
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
    @objc func about() { aboutWindow.show() }
    @objc func instructions() { showInfo(tr("Instructions", "Инструкция"), tr("Click an instance to switch. Shift-click or middle-click requests a new independent process. Right-click for windows and process actions. Use Tab and Space for buttons, Control-click or Shift-F10 for menus.\n\nWMac coexists with the system Dock. You may enable Dock auto-hide or move it to a side in System Settings → Desktop & Dock. WMac can temporarily hide Dock with explicit consent in General settings; it restores the original preferences when the mode is disabled or WMac quits. It never reserves screen space. Hide panels from the menu bar if they interfere. Fullscreen and Spaces behavior needs verification on your display setup.", "Нажмите на экземпляр для переключения. Shift-клик или средний клик запрашивает новый процесс. Правый клик открывает окна и действия. Tab и пробел управляют кнопками, Control-клик или Shift-F10 — меню.\n\nСистемный Dock остаётся доступен. Автоскрытие или расположение сбоку можно включить в Системных настройках → Рабочий стол и Dock. WMac может временно скрывать Dock по вашему выбору в разделе «Общие», восстанавливая прежние параметры при выключении режима или выходе. Экранное пространство не резервируется. При необходимости скройте панели из строки меню. Полноэкранный режим и Spaces требуют проверки на вашем оборудовании.")) }
    @objc func requestPermission() { permissions.requestAccessFromUserAction() }
    @objc func permissionSettings() { permissions.openSettingsFromUserAction() }
    func requestScreenRecording() {
        // Only explicit user actions may initiate a TCC request.
        let allowed = CGRequestScreenCaptureAccess()
        if !allowed, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        settingsWindow.refresh()
        notify(allowed ? tr("Screen Recording enabled; reopen the preview (macOS may require restarting WMac).", "Запись экрана разрешена. Откройте предпросмотр снова (macOS может потребовать перезапуск WMac).") :
                 tr("Allow WMac in Screen & System Audio Recording settings.", "Разрешите WMac доступ в настройках записи экрана и системного звука."))
    }
    @objc func dockSettings() { if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") { NSWorkspace.shared.open(url) } }
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
        func action(_ en: String, _ ru: String, _ command: String) {
            let item = NSMenuItem(title: tr(en, ru), action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuCommand(capture: capture, action: command)
            menu.addItem(item)
        }
        func separator() { menu.addItem(.separator()) }
        action(capture.instance == nil ? "Open" : "Switch", capture.instance == nil ? "Открыть" : "Переключиться", "switch")
        action("New instance", "Новый экземпляр", "new")
        if capture.instance != nil {
            action("Windows…", "Окна…", "preview")
            separator()
            action("Hide", "Скрыть", "hide")
            action("Terminate this instance", "Завершить этот экземпляр", "terminate")
            action("Force terminate…", "Завершить принудительно…", "force")
        }
        separator()
        if case .pin(let id) = capture.button {
            action("Unpin", "Открепить", "unpin")
            if let pin = coordinator.pins.first(where: { $0.pin.id == id }), pin.availability == .missing {
                action("Application not found — choose replacement…", "Приложение не найдено — выбрать новый путь…", "relink")
            }
        } else if capture.application != nil { action("Pin", "Закрепить", "pin") }
        if let index = coordinator.snapshot.buttons.firstIndex(where: { $0.id == capture.button }) {
            if index > 0 { action("Move left", "Переместить влево", "reorderLeft") }
            if index + 1 < coordinator.snapshot.buttons.count { action("Move right", "Переместить вправо", "reorderRight") }
        }
        separator()
        action("Reveal in Finder", "Показать в Finder", "reveal")
        return menu
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? MenuCommand, valid(command.capture) else { notify(tr("Stale action rejected", "Устаревшее действие отклонено")); return }
        let capture = command.capture
        switch command.action {
        case "pin":
            pinMutations.submit(.pin(capture))
        case "unpin": pinMutations.submit(.remove(capture))
        case "reorderLeft", "reorderRight":
            if let index = coordinator.snapshot.buttons.firstIndex(where: { $0.id == capture.button }) {
                moveButton(capture, to: command.action == "reorderLeft" ? index - 1 : index + 2)
            }
        case "relink": chooseReplacement(capture)
        case "switch": click(capture, new: false)
        case "new": click(capture, new: true)
        case "preview": previews.openExplicit(capture)
        case "hide": if let id = capture.instance { _ = monitor.running(id)?.hide(); previews.close() }
        case "terminate": if let id = capture.instance { _ = monitor.terminate(id); previews.close() }
        case "force":
            let alert = NSAlert(); alert.messageText = tr("Force terminate this instance?", "Принудительно завершить этот экземпляр?"); alert.informativeText = tr("Unsaved work may be lost. PID: ", "Несохранённые данные могут быть потеряны. PID: ") + (capture.instance?.pid.description ?? "")
            alert.addButton(withTitle: tr("Cancel", "Отмена")); alert.addButton(withTitle: tr("Force terminate", "Завершить")); NSApp.activate()
            if alert.runModal() == .alertSecondButtonReturn, valid(capture), let id = capture.instance { _ = monitor.running(id)?.forceTerminate() }
        case "reveal": if let url = capture.application?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        default: break
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The updater already awaited persistence and restored Dock. Returning
        // terminateLater here would queue a MainActor task while terminate()
        // is still occupying that actor inside AppKit's nested termination loop.
        if updates.installing && updateRestartReady { return .terminateNow }
        if updates.installing && !updateRestartReady { return .terminateCancel }
        Task {
            await settings.settled()
            await pinMutations.wait()
            dockVisibility.restore()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { previews.close(); dockVisibility.restore(); clock?.invalidate(); monitor.stop(); displays.close(); for token in tokens { NotificationCenter.default.removeObserver(token) } }
}
