import AppKit

@MainActor final class ApplicationUpdateController: NSObject, NSMenuItemValidation {
    private let service = ApplicationUpdateService()
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private(set) var busy = false
    private(set) var installing = false
    var changed: (() -> Void)?
    var prepareRestart: (() async -> Void)?
    var automatic: Bool {
        get { defaults.object(forKey: "automaticUpdateChecks") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "automaticUpdateChecks") }
    }
    func start() {
        guard !_isDebugAssertConfiguration() else { return }
        Task { await check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(manual: false) }
        }
    }
    func addCommands(to menu: NSMenu) {
        let check = NSMenuItem(title: busy ? tr("Updating…", "Обновление…") : tr("Check for Updates…", "Проверить обновления…"), action: #selector(checkNow), keyEquivalent: "")
        check.target = self; check.isEnabled = !busy
        menu.addItem(check)
        let automatic = NSMenuItem(title: tr("Automatically check for updates", "Проверять обновления автоматически"), action: #selector(toggleAutomatic), keyEquivalent: "")
        automatic.target = self; automatic.state = self.automatic ? .on : .off
        menu.addItem(automatic)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(checkNow) || !busy
    }
    @objc private func checkNow() { Task { await check(manual: true) } }
    @objc private func toggleAutomatic() { automatic.toggle(); changed?() }
    private func message(_ title: String, _ details: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = details
        alert.addButton(withTitle: tr("OK", "ОК")); NSApp.activate(); alert.runModal()
    }
    func check(manual: Bool) async {
        guard !busy, manual || automatic else { return }
        busy = true; changed?()
        defer { busy = false; installing = false; changed?() }
        do {
            guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  let version = ReleaseVersion(current) else { throw UpdateError.unavailable }
            let release = try await service.latest()
            guard let latest = release.version, latest > version else {
                if manual { message(tr("WMac is up to date", "Установлена актуальная версия WMac"), current) }
                return
            }
            let alert = NSAlert()
            alert.messageText = tr("WMac \(release.tag_name) is available", "Доступна WMac \(release.tag_name)")
            let supported = ApplicationUpdateService.supported(Bundle.main.bundleURL) && release.package != nil
            alert.informativeText = supported ? tr(
                "Download, verify and install the update, then restart WMac. Your settings and pins are preserved. macOS may ask you to approve the app or Accessibility again.",
                "Загрузить, проверить и установить обновление, затем перезапустить WMac. Настройки и закрепления сохранятся. macOS может повторно запросить разрешение запуска или Универсальный доступ.") : tr(
                "Automatic installation requires a writable WMac.app in Applications and a release DMG with a checksum. Open the release page to install manually.",
                "Для автоматической установки нужна доступная для записи WMac.app в Applications и релизный DMG с контрольной суммой. Откройте страницу релиза для ручной установки.")
            alert.addButton(withTitle: supported ? tr("Install and Restart", "Установить и перезапустить") : tr("Open Release", "Открыть релиз"))
            alert.addButton(withTitle: tr("Later", "Позже"))
            if supported { alert.addButton(withTitle: tr("Release Notes", "Что нового")) }
            NSApp.activate()
            let response = alert.runModal()
            if response == .alertThirdButtonReturn || (!supported && response == .alertFirstButtonReturn) {
                NSWorkspace.shared.open(release.html_url); return
            }
            guard supported, response == .alertFirstButtonReturn else { return }
            installing = true
            let progress = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            progress.title = tr("Updating WMac", "Обновление WMac")
            let text = NSTextField(labelWithString: tr("Downloading, verifying and installing…", "Загрузка, проверка и установка…"))
            text.frame = NSRect(x: 20, y: 56, width: 400, height: 20)
            let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 25, width: 400, height: 16))
            spinner.style = .bar; spinner.isIndeterminate = true; spinner.startAnimation(nil)
            progress.contentView?.addSubview(text); progress.contentView?.addSubview(spinner)
            progress.center(); progress.makeKeyAndOrderFront(nil)
            defer { progress.close() }
            let destination = Bundle.main.bundleURL
            let backup = try await service.install(release, destination: destination)
            await prepareRestart?()
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.activates = true
            config.arguments = ["--updated-from-pid", String(ProcessInfo.processInfo.processIdentifier)]
            do {
                let launched = try await NSWorkspace.shared.openApplication(at: destination, configuration: config)
                guard launched.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      !launched.isTerminated else { throw UpdateError.unavailable }
            } catch {
                try await service.restore(backup: backup, destination: destination)
                throw error
            }
            // The previous bundle is intentionally retained for manual recovery.
            NSApp.terminate(nil)
        } catch {
            if manual || installing {
                message(tr("Update unavailable", "Обновление недоступно"), tr(
                    "WMac could not check or install the update. Your current session remains open. Try again or install from GitHub Releases. macOS security settings were not changed.",
                    "Не удалось проверить или установить обновление. Текущий сеанс продолжает работу. Повторите попытку или установите версию из GitHub Releases. Настройки безопасности macOS не изменялись."))
            }
        }
    }
}
