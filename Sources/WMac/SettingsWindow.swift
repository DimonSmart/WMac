import AppKit
import ServiceManagement

/// Observes OS state; persistence never claims login registration succeeded.
@MainActor final class LoginItemService {
    private(set) var error: String?
    var explanation: String {
        let state: String
        switch SMAppService.mainApp.status {
        case .enabled: state = tr("Enabled", "Включён")
        case .notRegistered: state = tr("Not registered", "Не зарегистрирован")
        case .requiresApproval: state = tr("Approval required or access denied. Allow WMac in Login Items.", "Требуется одобрение или доступ запрещён. Разрешите WMac в объектах входа.")
        case .notFound: state = tr("App service not found. Install WMac in Applications.", "Сервис приложения не найден. Установите WMac в Программы.")
        @unknown default: state = tr("Unknown system status", "Неизвестное состояние системы")
        }
        return state + (error.map { "\n" + $0 } ?? "")
    }
    func enable() { do { try SMAppService.mainApp.register(); error = nil } catch { self.error = error.localizedDescription } }
    func disable() async { do { try await SMAppService.mainApp.unregister(); error = nil } catch { self.error = error.localizedDescription } }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
@MainActor private final class SettingButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
    var perform: (() -> Void)?
    convenience init(_ title: String, perform: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil); self.perform = perform; target = self; action = #selector(run)
        setAccessibilityLabel(title); identifier = NSUserInterfaceItemIdentifier(title)
    }
    @objc private func run() { perform?() }
}
@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    unowned let runtime: TaskbarDelegate
    let login = LoginItemService()
    private let tabs = NSTabView()
    private var observer: NSObjectProtocol?
    init(runtime: TaskbarDelegate) {
        self.runtime = runtime
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 610), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = tr("WMac! Settings", "Настройки WMac!"); window.minSize = NSSize(width: 640, height: 550)
        window.isReleasedWhenClosed = false; window.delegate = self; window.setFrameAutosaveName("WMacSettings")
        tabs.frame = NSRect(x: 18, y: 18, width: 644, height: 574); tabs.autoresizingMask = [.width, .height]; window.contentView?.addSubview(tabs); window.initialFirstResponder = tabs
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        refresh(); window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func show() { NSApp.setActivationPolicy(.regular); refresh(); showWindow(nil); NSApp.activate(); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(tabs) }
    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
    private func text(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value); label.font = .systemFont(ofSize: 13); label.setAccessibilityLabel(value); return label
    }
    private func section(_ title: String) -> NSStackView {
        let item = NSTabViewItem(identifier: title); item.label = title
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 18, bottom: 20, right: 18); stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack; item.view = scroll; tabs.addTabViewItem(item)
        NSLayoutConstraint.activate([stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 450)])
        return stack
    }
    private func button(_ stack: NSStackView, _ title: String, _ action: @escaping () -> Void) { stack.addArrangedSubview(SettingButton(title, perform: action)) }
    private func toggle(_ stack: NSStackView, _ title: String, _ on: Bool, _ action: @escaping (Bool) -> Void) {
        let b = SettingButton(title, perform: {}); b.setButtonType(.switch); b.state = on ? .on : .off
        b.perform = { [weak b] in action(b?.state == .on) }; b.isEnabled = runtime.settings.ready
        stack.addArrangedSubview(b)
    }
    func refresh() {
        let focused = (window?.firstResponder as? NSView)?.identifier
        let selected = tabs.selectedTabViewItem.map { tabs.indexOfTabViewItem($0) } ?? 0
        while let first = tabs.tabViewItems.first { tabs.removeTabViewItem(first) }
        let value = runtime.settings.value
        let general = section(tr("General", "Общие"))
        if let error = runtime.settings.failure {
            general.addArrangedSubview(text(error + tr("\nRetry after restoring a compatible file, or recover defaults with a preserved backup. Pins remain saved separately.", "\nВосстановите совместимый файл и повторите загрузку либо восстановите исходные настройки с резервной копией. Закрепления сохранены отдельно.")))
            button(general, tr("Retry settings", "Повторить загрузку")) { [weak self] in self?.runtime.settings.load() }
            button(general, tr("Recover settings…", "Восстановить настройки…")) { [weak self] in self?.confirmReset(recovery: true) }
        }
        toggle(general, tr("Panels on all displays (off: primary display only)", "Панели на всех экранах (выкл.: только основной)"), value.allDisplays) { [weak self] on in self?.runtime.settings.edit { $0.allDisplays = on } }
        general.addArrangedSubview(text(tr("Launch at login: ", "Запуск при входе: ") + login.explanation))
        button(general, tr("Enable launch at login", "Включить запуск при входе")) { [weak self] in self?.login.enable(); self?.refresh() }
        button(general, tr("Disable launch at login", "Отключить запуск при входе")) { [weak self] in Task { await self?.login.disable(); self?.refresh() } }
        button(general, tr("Login Items settings…", "Настройки объектов входа…")) { [weak self] in self?.login.openSettings() }
        toggle(general, tr("Hide system Dock while WMac runs", "Скрывать системный Dock, пока работает WMac"), value.hideSystemDock) { [weak self] on in
            guard let self else { return }
            if on { self.confirmDockHiding() }
            else { self.runtime.settings.edit { $0.hideSystemDock = false } }
        }
        switch runtime.dockVisibility.status {
        case .active:
            general.addArrangedSubview(text(tr("System Dock hidden", "Системный Dock скрыт")))
        case .failed(let reason):
            general.addArrangedSubview(text(tr("Could not hide Dock: ", "Не удалось скрыть Dock: ") + reason))
        case .inactive:
            if value.hideSystemDock && runtime.displays.hidden {
                general.addArrangedSubview(text(tr("Paused: WMac taskbars are hidden", "Приостановлено: панели WMac скрыты")))
            }
        }
        if runtime.dockVisibility.needsRecovery {
            button(general, tr("Restore system Dock", "Восстановить системный Dock")) { [weak self] in self?.runtime.restoreSystemDock() }
        }
        button(general, tr("Dock settings…", "Настройки Dock…")) { [weak self] in self?.runtime.dockSettings() }
        button(general, tr("Show Dock guidance", "Показать инструкцию Dock")) { [weak self] in self?.runtime.instructions() }
        button(general, tr("Quit WMac!", "Выйти из WMac!")) { [weak self] in self?.runtime.quit() }
        let appearance = section(tr("Appearance", "Вид"))
        appearance.addArrangedSubview(text(tr("Panel height: \(Int(value.height)) pt", "Высота панели: \(Int(value.height)) пт")))
        let height = NSSlider(value: value.height, minValue: 40, maxValue: 64, target: self, action: #selector(heightChanged(_:)))
        height.identifier = NSUserInterfaceItemIdentifier("height"); height.isContinuous = false; height.numberOfTickMarks = 25; height.allowsTickMarkValuesOnly = true; height.setAccessibilityLabel(tr("Panel height", "Высота панели")); height.widthAnchor.constraint(equalToConstant: 380).isActive = true; appearance.addArrangedSubview(height)
        let theme = NSPopUpButton(); theme.identifier = NSUserInterfaceItemIdentifier("theme"); theme.addItems(withTitles: [tr("System", "Системная"), tr("Light", "Светлая"), tr("Dark", "Тёмная")]); theme.selectItem(at: WMacSettings.Theme.allCases.firstIndex(of: value.theme) ?? 0); theme.target = self; theme.action = #selector(themeChanged(_:)); theme.setAccessibilityLabel(tr("Appearance", "Оформление")); appearance.addArrangedSubview(theme)
        appearance.addArrangedSubview(text(tr("Background opacity: \(Int(value.opacity * 100))% (35–100%). Labels appear in tooltips.", "Непрозрачность фона: \(Int(value.opacity * 100))% (35–100%). Подписи — в подсказках.")))
        let opacity = NSSlider(value: value.opacity, minValue: 0.35, maxValue: 1, target: self, action: #selector(opacityChanged(_:))); opacity.identifier = NSUserInterfaceItemIdentifier("opacity"); opacity.isContinuous = false; opacity.widthAnchor.constraint(equalToConstant: 380).isActive = true; opacity.setAccessibilityLabel(tr("Background opacity", "Непрозрачность фона")); appearance.addArrangedSubview(opacity)
        for control in [height as NSControl, theme, opacity] { control.isEnabled = runtime.settings.ready }
        let behavior = section(tr("Behavior", "Поведение"))
        behavior.addArrangedSubview(text(tr("Shift-click always requests a new independent instance.", "Shift + клик всегда запрашивает новый независимый экземпляр.")))
        toggle(behavior, tr("Middle-click requests a new instance", "Средний клик запрашивает новый экземпляр"), value.middleClick) { [weak self] on in self?.runtime.settings.edit { $0.middleClick = on } }
        behavior.addArrangedSubview(text(tr("Click an instance to switch to it; click the active instance again to minimize its window. Window control requires Accessibility. Without it, the exact process is activated.", "Нажмите на экземпляр, чтобы переключиться на него; повторное нажатие на активный экземпляр свернёт его окно. Для управления окнами нужен Универсальный доступ. Без него активируется точный процесс.")))
        let apps = section(tr("Applications", "Приложения"))
        apps.addArrangedSubview(text(tr("Pinned applications — use each menu to reorder, unpin or relink:", "Закрепления — меню позволяет изменить порядок, открепить или восстановить путь:")))
        for pin in runtime.coordinator.pins {
            let b = NSPopUpButton(title: pin.pin.name, target: nil, action: nil); b.pullsDown = true
            b.menu?.addItem(withTitle: pin.pin.name, action: nil, keyEquivalent: "")
            // A captured coordinator button retains exact instance semantics.
            if let button = runtime.coordinator.snapshot.buttons.first(where: { $0.pinID == pin.pin.id }) {
                for item in runtime.contextMenu(ButtonCapture(button)).items { item.menu?.removeItem(item); b.menu?.addItem(item) }
            } else { b.menu?.addItem(withTitle: tr("Excluded (restore below to manage)", "Исключено (верните ниже для управления)"), action: nil, keyEquivalent: "") }
            b.setAccessibilityLabel(pin.pin.name); apps.addArrangedSubview(b)
        }
        apps.addArrangedSubview(text(tr("Exclusions hide both running buttons and pins; saved pins remain intact.", "Исключения скрывают процессы и закрепления; сохранённые закрепления остаются.")))
        button(apps, tr("Exclude application…", "Исключить приложение…")) { [weak self] in self?.excludeApplication() }
        for definition in value.exclusions {
            button(apps, tr("Restore: ", "Вернуть: ") + definition.url.path) { [weak self] in self?.runtime.settings.edit { $0.exclusions.removeAll { $0 == definition } } }
        }
        button(apps, tr("Reset settings…", "Сбросить настройки…")) { [weak self] in self?.confirmReset(recovery: false) }
        let permissions = section(tr("Permissions", "Разрешения"))
        permissions.addArrangedSubview(text(runtime.permissions.trusted ? tr("Accessibility: enabled", "Универсальный доступ: включён") : tr("Accessibility: unavailable", "Универсальный доступ: недоступен")))
        permissions.addArrangedSubview(text(tr("Accessibility enables window listing, selection, restore and minimization. Process discovery, pins, launching, switching by PID and termination work without it. Screen Recording is never requested.", "Универсальный доступ позволяет выбирать, восстанавливать и сворачивать окна. Процессы, закрепления, запуск, переключение по PID и завершение работают без него. Запись экрана не запрашивается.")))
        button(permissions, tr("Request Accessibility…", "Запросить Универсальный доступ…")) { [weak self] in self?.runtime.requestPermission(); self?.refresh() }
        button(permissions, tr("Open Accessibility settings…", "Открыть настройки Универсального доступа…")) { [weak self] in self?.runtime.permissionSettings() }
        button(permissions, tr("Refresh status", "Обновить статус")) { [weak self] in self?.refresh() }
        tabs.selectTabViewItem(at: max(0, min(selected, tabs.numberOfTabViewItems - 1)))
        if let focused {
            func matching(_ view: NSView) -> NSView? {
                if view.identifier == focused { return view }
                return view.subviews.lazy.compactMap { matching($0) }.first
            }
            if let root = tabs.selectedTabViewItem?.view, let next = matching(root) { window?.makeFirstResponder(next) }
        }
    }
    @objc private func heightChanged(_ sender: NSSlider) { let v = sender.doubleValue; runtime.settings.edit { $0.height = v } }
    @objc private func themeChanged(_ sender: NSPopUpButton) { let v = WMacSettings.Theme.allCases[sender.indexOfSelectedItem]; runtime.settings.edit { $0.theme = v } }
    @objc private func opacityChanged(_ sender: NSSlider) { let v = sender.doubleValue; runtime.settings.edit { $0.opacity = v } }
    private func excludeApplication() {
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.applicationBundle]; picker.allowsMultipleSelection = false
        guard let window else { return }
        picker.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = picker.url else { return }
            Task { @MainActor in
                guard let self else { return }
                guard let pin = await self.runtime.pins.prepare(url: url) else { return }
                let definition = pin.pin.application
                self.runtime.settings.edit { if !$0.exclusions.contains(definition) { $0.exclusions.append(definition) } }
            }
        }
    }
    private func confirmDockHiding() {
        let alert = NSAlert()
        alert.messageText = tr("Hide system Dock?", "Скрыть системный Dock?")
        alert.informativeText = tr(
            "WMac will change the system Dock's auto-hide preferences. Their original values will be saved and restored when this option is disabled or WMac quits. The Dock will restart to apply the changes.",
            "WMac изменит настройки автоматического скрытия системного Dock. Исходные значения будут сохранены и восстановлены при отключении этой функции или завершении WMac. Для применения настроек системный Dock будет перезапущен.")
        alert.addButton(withTitle: tr("Enable", "Включить"))
        alert.addButton(withTitle: tr("Cancel", "Отмена"))
        guard let window else { refresh(); return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.runtime.settings.edit { $0.hideSystemDock = true }
            } else { self.refresh() }
        }
    }
    private func confirmReset(recovery: Bool) {
        let alert = NSAlert(); alert.messageText = tr("Restore default settings?", "Восстановить исходные настройки?")
        alert.informativeText = tr("Pins and their order are preserved. Login registration is controlled separately. Recovery keeps a copy of the original settings file.", "Закрепления и порядок сохранятся. Запуск при входе управляется отдельно. Восстановление сохраняет копию исходного файла.")
        alert.addButton(withTitle: tr("Restore", "Восстановить")); alert.addButton(withTitle: tr("Cancel", "Отмена"))
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn, let self else { return }
            if recovery { runtime.settings.recover() }
            else { runtime.settings.edit { $0 = WMacSettings(); $0.dockGuidanceSeen = true } }
        }
    }
}
