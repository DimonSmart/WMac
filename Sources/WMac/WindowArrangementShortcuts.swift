import AppKit
import Carbon.HIToolbox

@MainActor
final class WindowArrangementShortcuts {
    private struct Shortcut {
        let operation: WindowArrangement
        let keyCode: UInt32
        let modifiers: UInt32
        var id: UInt32 { operation.rawValue + 1 }
    }
    private struct WindowKey: Hashable {
        let instance: InstanceID
        let window: UUID
    }

    private let accessibility: AccessibilityService
    private let permissions: AccessibilityPermissionService
    private var eventHandler: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var savedFrames: [WindowKey: CGRect] = [:]
    private var permissionPrompted = false
    private(set) var enabled = false
    private(set) var registrationError: String?
    var changed: (() -> Void)?
    var notify: ((String, String) -> Void)?

    init(accessibility: AccessibilityService, permissions: AccessibilityPermissionService) {
        self.accessibility = accessibility
        self.permissions = permissions
    }

    var statusMessage: String? {
        guard enabled else { return nil }
        if let registrationError { return tr("Window shortcuts unavailable: ", "Сочетания окон недоступны: ") + registrationError }
        if !accessibility.trusted {
            return tr("Enable Accessibility to move and resize windows.", "Включите Универсальный доступ, чтобы перемещать окна и менять их размер.")
        }
        return tr("Window shortcuts are active while WMac is running.", "Сочетания окон действуют, пока запущен WMac.")
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        registrationError = nil
        if enabled {
            guard installHandler() else {
                registrationError = tr("Could not register the keyboard handler.", "Не удалось зарегистрировать обработчик клавиатуры.")
                changed?()
                return
            }
            for shortcut in Self.shortcuts {
                let identifier = EventHotKeyID(signature: OSType(0x574D6163), id: shortcut.id)
                var reference: EventHotKeyRef?
                let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                                                 GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
                guard status == noErr, let reference else {
                    unregisterAll()
                    registrationError = tr("A shortcut is already in use or could not be registered (OSStatus \(status)).",
                                           "Сочетание уже используется или не зарегистрировано (OSStatus \(status)).")
                    changed?()
                    return
                }
                registrations[shortcut.id] = reference
            }
        } else {
            unregisterAll()
        }
        changed?()
    }

    private func installHandler() -> Bool {
        guard eventHandler == nil else { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = InstallEventHandler(GetApplicationEventTarget(), windowArrangementHotKeyHandler,
                                         1, &eventType, context, &eventHandler)
        return status == noErr
    }

    private func unregisterAll() {
        for reference in registrations.values { UnregisterEventHotKey(reference) }
        registrations.removeAll()
    }

    fileprivate func handleHotKey(_ id: UInt32) {
        guard enabled, let shortcut = Self.shortcuts.first(where: { $0.id == id }) else { return }
        let operation = shortcut.operation
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular,
              let startDate = ProcessLifetime.startDate(for: app) else { return }
        let instance = InstanceID(pid: app.processIdentifier, startDate: startDate)
        guard accessibility.trusted else {
            if !permissionPrompted {
                permissionPrompted = true
                notify?(tr("Window shortcuts need Accessibility", "Для сочетаний окон нужен Универсальный доступ"),
                        tr("Allow WMac in System Settings → Privacy & Security → Accessibility, then try the shortcut again.",
                           "Разрешите WMac в Системных настройках → Конфиденциальность и безопасность → Универсальный доступ, затем повторите сочетание."))
                permissions.requestAccessFromUserAction()
            }
            return
        }
        permissionPrompted = false
        Task { [weak self] in await self?.apply(operation, to: instance) }
    }

    private func apply(_ operation: WindowArrangement, to instance: InstanceID) async {
        guard enabled else { return }
        let windows: [WindowReference]
        switch await accessibility.windows(for: instance) {
        case .unavailable(let reason, _):
            notify?(tr("Window shortcut could not be applied", "Не удалось выполнить сочетание окон"), reason)
            return
        case .windows(let values, _): windows = values
        }
        guard let window = windows.first(where: { $0.isFocused && !$0.isMinimized }),
              let current = window.frame,
              let workArea = Self.accessibilityWorkArea(for: current) else {
            notify?(tr("No focused manageable window", "Нет сфокусированного управляемого окна"),
                    tr("The shortcut only acts on the current window of the frontmost application.",
                       "Сочетание действует только на текущее окно активной программы."))
            return
        }

        let key = WindowKey(instance: instance, window: window.id)
        let target: CGRect
        if operation == .restore {
            guard let saved = savedFrames[key] else {
                notify?(tr("No previous window position", "Нет сохранённого положения окна"),
                        tr("Restore is available after the first window arrangement in this WMac session.",
                           "Восстановление доступно после первого изменения положения окна в этом сеансе WMac."))
                return
            }
            target = saved
        } else {
            guard let frame = operation.targetFrame(current: current, workArea: workArea) else { return }
            if savedFrames[key] == nil { savedFrames[key] = current }
            target = frame
        }

        let result = await accessibility.arrange(instance, windowID: window.id, frame: target)
        guard enabled else { return }
        guard result.outcome == .arranged else {
            notify?(tr("Window shortcut could not be applied", "Не удалось выполнить сочетание окон"), result.message)
            return
        }
        if operation == .restore { savedFrames[key] = nil }
        if savedFrames.count > 256, let stale = savedFrames.keys.first { savedFrames.removeValue(forKey: stale) }
    }

    /// AXPosition and CGWindowBounds use a top-left global origin; NSScreen uses a
    /// bottom-left origin. Convert the visible AppKit work area before AX writes.
    private static func accessibilityWorkArea(for accessibilityFrame: CGRect) -> CGRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let primary = screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        } ?? screens[0]
        let primaryTop = primary.frame.maxY
        let appKitFrame = CGRect(x: accessibilityFrame.minX, y: primaryTop - accessibilityFrame.maxY,
                                 width: accessibilityFrame.width, height: accessibilityFrame.height)
        let center = CGPoint(x: appKitFrame.midX, y: appKitFrame.midY)
        let screen = screens.min { distance(center, to: $0.frame) < distance(center, to: $1.frame) }
        guard let screen else { return nil }
        let visible = screen.visibleFrame
        let area = CGRect(x: visible.minX, y: primaryTop - visible.maxY, width: visible.width, height: visible.height)
        return area.width > 0 && area.height > 0 ? area : nil
    }

    private static func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    private static let shortcuts: [Shortcut] = {
        let base = UInt32(controlKey | optionKey)
        let tall = base | UInt32(shiftKey)
        return [
            Shortcut(operation: .left, keyCode: UInt32(kVK_LeftArrow), modifiers: base),
            Shortcut(operation: .right, keyCode: UInt32(kVK_RightArrow), modifiers: base),
            Shortcut(operation: .top, keyCode: UInt32(kVK_UpArrow), modifiers: base),
            Shortcut(operation: .bottom, keyCode: UInt32(kVK_DownArrow), modifiers: base),
            Shortcut(operation: .topLeft, keyCode: UInt32(kVK_ANSI_U), modifiers: base),
            Shortcut(operation: .topRight, keyCode: UInt32(kVK_ANSI_I), modifiers: base),
            Shortcut(operation: .bottomLeft, keyCode: UInt32(kVK_ANSI_J), modifiers: base),
            Shortcut(operation: .bottomRight, keyCode: UInt32(kVK_ANSI_K), modifiers: base),
            Shortcut(operation: .firstThird, keyCode: UInt32(kVK_ANSI_D), modifiers: base),
            Shortcut(operation: .centerThird, keyCode: UInt32(kVK_ANSI_F), modifiers: base),
            Shortcut(operation: .lastThird, keyCode: UInt32(kVK_ANSI_G), modifiers: base),
            Shortcut(operation: .firstTwoThirds, keyCode: UInt32(kVK_ANSI_E), modifiers: base),
            Shortcut(operation: .centerTwoThirds, keyCode: UInt32(kVK_ANSI_R), modifiers: base),
            Shortcut(operation: .lastTwoThirds, keyCode: UInt32(kVK_ANSI_T), modifiers: base),
            Shortcut(operation: .maximize, keyCode: UInt32(kVK_Return), modifiers: base),
            Shortcut(operation: .maximizeHeight, keyCode: UInt32(kVK_UpArrow), modifiers: tall),
            Shortcut(operation: .larger, keyCode: UInt32(kVK_ANSI_Equal), modifiers: base),
            Shortcut(operation: .smaller, keyCode: UInt32(kVK_ANSI_Minus), modifiers: base),
            Shortcut(operation: .center, keyCode: UInt32(kVK_ANSI_C), modifiers: base),
            Shortcut(operation: .restore, keyCode: UInt32(kVK_Delete), modifiers: base)
        ]
    }()
}

private func windowArrangementHotKeyHandler(_ nextHandler: EventHandlerCallRef?, _ event: EventRef?,
                                           _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData, GetEventKind(event) == UInt32(kEventHotKeyPressed) else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    let target = Unmanaged<WindowArrangementShortcuts>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor [weak target] in target?.handleHotKey(identifier.id) }
    return noErr
}
