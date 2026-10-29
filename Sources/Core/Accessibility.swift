import AppKit
@preconcurrency import ApplicationServices

struct WindowIdentity: Hashable, Sendable {
    let instance: InstanceID
    let axID: UUID
    let lifecycle: UInt64
}

struct WindowCaptureState: Equatable, Sendable {
    let identity: WindowIdentity
    let revision: UInt64
    let title: String
    let frame: CGRect?
    let minimized: Bool
}

struct WindowReference: Identifiable, Equatable, Sendable {
    let id: UUID
    let instance: InstanceID
    let title: String
    let isMinimized: Bool
    let isFocused: Bool
    let canMinimize: Bool
    var frame: CGRect? = nil
    var lifecycle: UInt64 = 0
    var stateRevision: UInt64 = 0
    var role: String? = nil
    var subrole: String? = nil

    var identity: WindowIdentity { WindowIdentity(instance: instance, axID: id, lifecycle: lifecycle) }
    var captureState: WindowCaptureState {
        WindowCaptureState(identity: identity, revision: stateRevision, title: title,
                           frame: frame, minimized: isMinimized)
    }
}
enum WindowResult: Sendable {
    case windows([WindowReference])
    case unavailable(String)
}
enum WindowAction: Sendable { case restore, minimize }
struct WindowActionResult: Sendable {
    enum Outcome: Equatable, Sendable { case restored, minimized, arranged, noManageableWindows, activatedOnly, unavailable }
    let outcome: Outcome
    let message: String
    let activationAccepted: Bool
}
struct AccessibilityPermissionStatus: Sendable {
    let trusted: Bool
    var explanation: String {
        trusted ? "Accessibility is enabled. Individual window control is available where supported by the application."
        : "Window selection, restore and minimize need Accessibility access. Process switching, launches, pins and termination remain available."
    }
}
struct AccessibilityPermissionService: Sendable {
    var trusted: Bool { AXIsProcessTrusted() }
    var status: AccessibilityPermissionStatus { AccessibilityPermissionStatus(trusted: trusted) }
    // Only explicit user actions call these. Passive status/startup never prompts.
    @MainActor func requestAccessFromUserAction() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    @MainActor func openSettingsFromUserAction() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// Controlled synchronous boundary: only the service's background queue calls it.
// Tests supply values without making claims about the host's actual permission.
struct AXWindowValue: @unchecked Sendable {
    let element: AXUIElement
    let title: String
    let minimized: Bool
    let focused: Bool
    let canMinimize: Bool
    var frame: CGRect? = nil
    var role: String? = nil
    var subrole: String? = nil
}
struct AccessibilityBoundary: Sendable {
    var observesWindows = true
    var trusted: @Sendable () -> Bool = { AXIsProcessTrusted() }
    var live: @Sendable (InstanceID) -> Bool = { id in
        guard let app = NSRunningApplication(processIdentifier: id.pid) else { return false }
        return !app.isTerminated && ProcessLifetime.startDate(for: app) == id.startDate
    }
    var read: @Sendable (InstanceID) -> Result<[AXWindowValue], AXFailure> = { id in
        let app = AXUIElementCreateApplication(id.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard error == .success, let elements = value as? [AXUIElement] else {
            return .failure(AXFailure(message: "Window enumeration unavailable (AX \(error.rawValue))."))
        }
        guard elements.count <= 64 else { return .failure(AXFailure(message: "Window enumeration exceeds the 64-window safety budget; process switching remains available.")) }
        var focused: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused)
        let deadline = Date().addingTimeInterval(3)
        var windows: [AXWindowValue] = []
        for element in elements.prefix(64) {
            guard Date() < deadline else { return .failure(AXFailure(message: "Window enumeration exceeded its time budget.")) }
            AXUIElementSetMessagingTimeout(element, 0.5)
            var subrole: CFTypeRef?
            let subroleError = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            guard subroleError == .success else { return .failure(AXFailure(message: "Window subrole temporarily unavailable (AX \(subroleError.rawValue)).")) }
            guard subrole as? String == kAXStandardWindowSubrole || subrole as? String == kAXDialogSubrole else { continue }
            var title: CFTypeRef?, minimized: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            // An unreadable minimized attribute is not a reliable actionable window.
            let minimizedError = AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
            guard minimizedError == .success else { return .failure(AXFailure(message: "Window minimized state temporarily unavailable (AX \(minimizedError.rawValue)).")) }
            var settable: DarwinBoolean = false
            _ = AXUIElementIsAttributeSettable(element, kAXMinimizedAttribute as CFString, &settable)
            // AppKit can expose minimized/restoring standard windows as
            // AXDialog. Require public window role and minimization support;
            // utility/popover and non-minimizable dialog subroles stay out.
            if subrole as? String != kAXStandardWindowSubrole {
                var role: CFTypeRef?
                guard subrole as? String == kAXDialogSubrole, settable.boolValue,
                      AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
                      role as? String == kAXWindowRole else { continue }
            }
            var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
            var frame: CGRect?
            if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
               AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
               let originRaw = positionValue, let sizeRaw = sizeValue,
               CFGetTypeID(originRaw) == AXValueGetTypeID(), CFGetTypeID(sizeRaw) == AXValueGetTypeID() {
                let originAX = originRaw as! AXValue
                let sizeAX = sizeRaw as! AXValue
                var origin = CGPoint.zero
                var size = CGSize.zero
                if AXValueGetValue(originAX, .cgPoint, &origin), AXValueGetValue(sizeAX, .cgSize, &size),
                   origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite,
                   size.width > 0, size.height > 0 {
                    frame = CGRect(origin: origin, size: size)
                }
            }
            windows.append(AXWindowValue(element: element, title: title as? String ?? "Window", minimized: minimized as? Bool ?? false,
                                         focused: focused.map { CFEqual($0, element) } ?? false, canMinimize: settable.boolValue, frame: frame,
                                         role: kAXWindowRole as String, subrole: subrole as? String))
        }
        return .success(windows)
    }
    var perform: @Sendable (InstanceID, AXUIElement, WindowAction) -> String? = { id, element, action in
        func valid() -> Bool {
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid == id.pid,
                  let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return !app.isTerminated && ProcessLifetime.startDate(for: app) == id.startDate
        }
        guard valid() else { return "Window process lifetime no longer matches." }
        AXUIElementSetMessagingTimeout(element, 0.5)
        let minimized = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                                     action == .minimize ? kCFBooleanTrue : kCFBooleanFalse)
        guard minimized == .success else { return "Cannot change window minimization (AX \(minimized.rawValue))." }
        if action == .restore {
            guard valid() else { return "Process exited while restoring window." }
            // Deminiaturization animation can temporarily reject raise. Retry
            // only transient cannotComplete responses within a fixed deadline.
            let deadline = Date().addingTimeInterval(1.5)
            while true {
                guard valid() else { return "Process exited before raising window." }
                let main = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                guard valid() else { return "Process exited before raising window." }
                let raise = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                if main == .success && raise == .success { break }
                guard (main == .success || main == .cannotComplete), (raise == .success || raise == .cannotComplete), Date() < deadline else {
                    return "Window restored, but main/raise was limited (AX \(main.rawValue)/\(raise.rawValue))."
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return nil
    }
    var activate: @MainActor @Sendable (InstanceID) -> Bool = { id in
        guard let app = NSRunningApplication(processIdentifier: id.pid), !app.isTerminated,
              ProcessLifetime.startDate(for: app) == id.startDate else { return false }
        NSApplication.shared.yieldActivation(to: app)
        return app.activate(options: [])
    }
}
struct AXFailure: Error, Sendable { let message: String }

final class AccessibilityService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.wmac.accessibility")
    private let boundary: AccessibilityBoundary
    private struct Record { let snapshot: WindowReference; let element: AXUIElement }
    private struct State {
        var records: [Record] = []
        var lastActive: UUID?
        var minimizedByToggle: UUID?
    }
    // Access only on queue. A returned snapshot contains no actionable AX object.
    private var states: [InstanceID: State] = [:]
    // Queue-confined, monotonically allocated even after a process is invalidated.
    private var nextWindowLifecycle: UInt64 = 0
    private var nextObservedRevision: UInt64 = 0
    private var observations: [InstanceID: WindowObservation] = [:]
    // Subscribers observe changes through the existing AX observer; no second
    // independent AX window inventory or observer is created.
    private var listeners: [InstanceID: [UUID: @Sendable () -> Void]] = [:]
    private var unavailableInstances: Set<InstanceID> = []
    private var pendingObserverRefreshes: Set<InstanceID> = []
    private var processTokens: [NSObjectProtocol] = []
    var trusted: Bool { boundary.trusted() }
    init(boundary: AccessibilityBoundary = AccessibilityBoundary()) {
        self.boundary = boundary
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            processTokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                let terminated = note.name == NSWorkspace.didTerminateApplicationNotification
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    for id in Array(self.states.keys) where id.pid == pid {
                        if terminated || !self.boundary.live(id) { self.invalidate(id) }
                        else { _ = self.refresh(id) }
                    }
                }
            })
        }
    }
    deinit { for token in processTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) } }
    // Move/resize notifications can arrive for every pixel. Coalesce them on the
    // existing AX queue so event-driven previews do not queue hundreds of reads.
    private func scheduleObserverRefresh(_ id: InstanceID) {
        guard pendingObserverRefreshes.insert(id).inserted else { return }
        queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.pendingObserverRefreshes.remove(id)
            _ = self.refresh(id)
        }
    }
    private func publishChange(_ id: InstanceID) {
        guard let callbacks = listeners[id] else { return }
        for callback in callbacks.values { callback() }
    }
    func listen(_ instance: InstanceID, changed: @escaping @Sendable () -> Void) async -> UUID {
        let token = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.listeners[instance, default: [:]][token] = changed
                continuation.resume()
            }
        }
        return token
    }
    func stopListening(_ instance: InstanceID, token: UUID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.listeners[instance]?.removeValue(forKey: token)
                if self.listeners[instance]?.isEmpty == true { self.listeners.removeValue(forKey: instance) }
                continuation.resume()
            }
        }
    }
    private func invalidate(_ id: InstanceID) {
        let existed = states.removeValue(forKey: id) != nil
        observations.removeValue(forKey: id)
        unavailableInstances.remove(id)
        if existed { publishChange(id) }
    }
    private func refresh(_ id: InstanceID) -> WindowResult {
        guard boundary.live(id) else { invalidate(id); return .unavailable("Process lifetime no longer matches.") }
        guard boundary.trusted() else {
            // Missing permission is unknown state, not evidence that the AX windows closed.
            if unavailableInstances.insert(id).inserted { publishChange(id) }
            return .unavailable("Accessibility unavailable. Process activation remains available.")
        }
        switch boundary.read(id) {
        case .failure(let error):
            // A transient timeout is unknown state; retain semantic identity but
            // make listeners discard images until a successful fresh read.
            if unavailableInstances.insert(id).inserted { publishChange(id) }
            return .unavailable(error.message)
        case .success(let values):
            guard boundary.live(id) else { invalidate(id); return .unavailable("Process exited during enumeration.") }
            var state = states[id] ?? State()
            let previous = state.records
            let wasUnavailable = unavailableInstances.remove(id) != nil
            var refreshed: [Record] = []
            for value in values {
                // Duplicate AX handles are one semantic window, never two competing cards.
                guard !refreshed.contains(where: { CFEqual($0.element, value.element) }) else { continue }
                let old = previous.first { CFEqual($0.element, value.element) }?.snapshot
                if old == nil { nextWindowLifecycle &+= 1 }
                let lifecycle = old?.lifecycle ?? nextWindowLifecycle
                let changed = old == nil || old?.title != value.title || old?.frame != value.frame ||
                    old?.isMinimized != value.minimized || old?.isFocused != value.focused ||
                    old?.canMinimize != value.canMinimize || old?.role != value.role || old?.subrole != value.subrole
                if changed { nextObservedRevision &+= 1 }
                let snapshot = WindowReference(id: old?.id ?? UUID(), instance: id, title: value.title,
                                               isMinimized: value.minimized, isFocused: value.focused,
                                               canMinimize: value.canMinimize, frame: value.frame,
                                               lifecycle: lifecycle,
                                               stateRevision: changed ? nextObservedRevision : (old?.stateRevision ?? 0),
                                               role: value.role, subrole: value.subrole)
                refreshed.append(Record(snapshot: snapshot, element: value.element))
            }
            state.records = refreshed
            let keys = Set(state.records.map { $0.snapshot.id })
            if let last = state.lastActive, !keys.contains(last) { state.lastActive = nil }
            if let toggled = state.minimizedByToggle, !keys.contains(toggled) { state.minimizedByToggle = nil }
            if let focused = state.records.first(where: { $0.snapshot.isFocused && !$0.snapshot.isMinimized }) { state.lastActive = focused.snapshot.id }
            states[id] = state
            if wasUnavailable || previous.map(\.snapshot) != state.records.map(\.snapshot) { publishChange(id) }
            // Observer callbacks reconcile closure/focus/title/minimize changes. A fresh
            // read before every action also covers apps with incomplete notifications.
            if !boundary.observesWindows { return .windows(state.records.map(\.snapshot)) }
            if observations[id] == nil {
                observations[id] = WindowObservation.create(pid: id.pid, windows: values.map(\.element)) { [weak self] in
                    self?.queue.async { [weak self] in self?.scheduleObserverRefresh(id) }
                }
            } else { observations[id]?.update(windows: values.map(\.element)) }
            return .windows(state.records.map(\.snapshot))
        }
    }
    func windows(for instance: InstanceID) async -> WindowResult {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.refresh(instance)) } }
    }
    func arrange(_ instance: InstanceID, windowID: UUID, frame: CGRect) async -> WindowActionResult {
        await withCheckedContinuation { continuation in
            queue.async {
                func result(_ outcome: WindowActionResult.Outcome, _ message: String) -> WindowActionResult {
                    WindowActionResult(outcome: outcome, message: message, activationAccepted: outcome == .arranged)
                }
                guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
                      frame.width > 0, frame.height > 0 else {
                    continuation.resume(returning: result(.unavailable, "The requested window geometry is invalid.")); return
                }
                guard self.boundary.trusted() else {
                    continuation.resume(returning: result(.unavailable, "Window arrangement needs Accessibility permission.")); return
                }
                guard case .windows = self.refresh(instance), let state = self.states[instance],
                      let record = state.records.first(where: { $0.snapshot.id == windowID && $0.snapshot.isFocused && !$0.snapshot.isMinimized }) else {
                    continuation.resume(returning: result(.unavailable, "The focused window changed or is no longer manageable.")); return
                }
                func stillFocused() -> Bool {
                    guard self.boundary.live(instance) else { return false }
                    let system = AXUIElementCreateSystemWide()
                    var appValue: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appValue) == .success,
                          let appValue, CFGetTypeID(appValue) == AXUIElementGetTypeID() else { return false }
                    let app = appValue as! AXUIElement
                    var pid: pid_t = 0
                    guard AXUIElementGetPid(app, &pid) == .success, pid == instance.pid else { return false }
                    var windowValue: CFTypeRef?
                    return AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success
                        && windowValue.map { CFEqual($0, record.element) } == true
                }
                guard stillFocused() else {
                    continuation.resume(returning: result(.unavailable, "The focused window changed before arrangement.")); return
                }
                AXUIElementSetMessagingTimeout(record.element, 0.5)
                var positionSettable = DarwinBoolean(false), sizeSettable = DarwinBoolean(false)
                let positionCheck = AXUIElementIsAttributeSettable(record.element, kAXPositionAttribute as CFString, &positionSettable)
                let sizeCheck = AXUIElementIsAttributeSettable(record.element, kAXSizeAttribute as CFString, &sizeSettable)
                guard positionCheck == .success, sizeCheck == .success, positionSettable.boolValue, sizeSettable.boolValue else {
                    continuation.resume(returning: result(.unavailable, "This application does not allow the focused window to be moved and resized.")); return
                }
                var origin = frame.origin, size = frame.size
                guard let position = AXValueCreate(.cgPoint, &origin), let dimensions = AXValueCreate(.cgSize, &size) else {
                    continuation.resume(returning: result(.unavailable, "Could not encode the requested window geometry.")); return
                }
                let sizeResult = AXUIElementSetAttributeValue(record.element, kAXSizeAttribute as CFString, dimensions)
                guard sizeResult == .success else {
                    continuation.resume(returning: result(.unavailable, "The application rejected the requested window size (AX \(sizeResult.rawValue)).")); return
                }
                guard stillFocused() else {
                    continuation.resume(returning: result(.unavailable, "The focused window changed while its size was being updated.")); return
                }
                let positionResult = AXUIElementSetAttributeValue(record.element, kAXPositionAttribute as CFString, position)
                guard positionResult == .success else {
                    continuation.resume(returning: result(.unavailable, "The application accepted the size but rejected the position (AX \(positionResult.rawValue)).")); return
                }
                continuation.resume(returning: result(.arranged, "Window arranged."))
            }
        }
    }
    // Optional independent observer for diagnostics. Caller owns its lifetime.
    func observe(_ instance: InstanceID, changed: @escaping @Sendable () -> Void) async -> WindowObservation? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.boundary.trusted(), self.boundary.live(instance) else { continuation.resume(returning: nil); return }
                continuation.resume(returning: WindowObservation.create(pid: instance.pid, windows: [], callback: changed))
            }
        }
    }
    private struct Prepared: Sendable { let outcome: WindowActionResult.Outcome; let message: String }
    func select(_ window: WindowReference) async -> WindowActionResult {
        await act(window.instance, selected: window.id, toggle: false, active: false)
    }
    func switchTo(_ instance: InstanceID, minimizeIfActive: Bool = false, isActive: Bool = false) async -> WindowActionResult {
        await act(instance, selected: nil, toggle: minimizeIfActive, active: isActive)
    }
    private func act(_ id: InstanceID, selected: UUID?, toggle: Bool, active: Bool) async -> WindowActionResult {
        let prepared: Prepared = await withCheckedContinuation { continuation in
            queue.async {
                let refreshed = self.refresh(id)
                if case .unavailable(let message) = refreshed {
                    continuation.resume(returning: Prepared(outcome: .activatedOnly, message: message + " Attempted process activation.")); return
                }
                guard var state = self.states[id] else {
                    continuation.resume(returning: Prepared(outcome: .activatedOnly, message: "Window state unavailable; attempted process activation.")); return
                }
                let selectedRecord: Record?
                if let selected { selectedRecord = state.records.first { $0.snapshot.id == selected } }
                else {
                    let preferred = state.minimizedByToggle ?? state.lastActive
                    selectedRecord = state.records.first { $0.snapshot.id == preferred }
                        ?? state.records.first { !$0.snapshot.isMinimized } ?? state.records.first
                }
                guard self.boundary.live(id) else {
                    continuation.resume(returning: Prepared(outcome: .unavailable, message: "Process lifetime no longer matches.")); return
                }
                guard let record = selectedRecord else {
                    let outcome: WindowActionResult.Outcome = selected == nil && state.records.isEmpty ? .noManageableWindows : .activatedOnly
                    continuation.resume(returning: Prepared(outcome: outcome, message: "No manageable window exists; attempted process activation.")); return
                }
                let minimize = selected == nil && toggle && active && state.minimizedByToggle == nil
                    && record.snapshot.isFocused && !record.snapshot.isMinimized
                if minimize && !record.snapshot.canMinimize {
                    continuation.resume(returning: Prepared(outcome: .activatedOnly, message: "Active window cannot be minimized; attempted process activation.")); return
                }
                if let error = self.boundary.perform(id, record.element, minimize ? .minimize : .restore) {
                    // Partial action failure does not prove destruction. Future
                    // actions still require a fresh enumeration and lifetime check.
                    continuation.resume(returning: Prepared(outcome: .activatedOnly, message: error + " Attempted process activation.")); return
                }
                guard self.boundary.live(id) else {
                    self.invalidate(id)
                    continuation.resume(returning: Prepared(outcome: .unavailable, message: "Process exited during window action.")); return
                }
                state.lastActive = record.snapshot.id
                state.minimizedByToggle = minimize ? record.snapshot.id : nil
                self.states[id] = state
                continuation.resume(returning: Prepared(outcome: minimize ? .minimized : .restored,
                                                       message: minimize ? "Minimized the focused window." : "Restored and raised the selected window."))
            }
        }
        // An explicit window selection must never fall back to activating an arbitrary window.
        if selected != nil && prepared.outcome != .restored {
            return WindowActionResult(outcome: .unavailable, message: prepared.message, activationAccepted: false)
        }
        let activated = await boundary.activate(id)
        let outcome: WindowActionResult.Outcome = activated ? prepared.outcome : .unavailable
        return WindowActionResult(outcome: outcome, message: prepared.message + (activated ? "" : " Process activation was rejected."), activationAccepted: activated)
    }
}

// The callback context is independent from the observation. Removal and final
// context release are ordered on the callback's main run loop, avoiding a
// callback racing deinit or retaining the service through an ownership cycle.
private final class AXCallback: @unchecked Sendable {
    let callback: @Sendable () -> Void
    init(_ callback: @escaping @Sendable () -> Void) { self.callback = callback }
}
final class WindowObservation: @unchecked Sendable {
    private let observer: AXObserver
    private let context: UnsafeMutableRawPointer
    private var registrations: [(AXUIElement, String)] = []
    private let application: AXUIElement
    private init(observer: AXObserver, application: AXUIElement, context: UnsafeMutableRawPointer) {
        self.observer = observer; self.application = application; self.context = context
    }
    private func register(_ element: AXUIElement, _ name: String) {
        guard !registrations.contains(where: { CFEqual($0.0, element) && $0.1 == name }) else { return }
        AXUIElementSetMessagingTimeout(element, 0.5)
        if AXObserverAddNotification(observer, element, name as CFString, context) == .success { registrations.append((element, name)) }
    }
    // Only called from the service background queue.
    func update(windows: [AXUIElement]) {
        let deadline = Date().addingTimeInterval(2)
        for (element, name) in registrations where !CFEqual(element, application) && !windows.contains(where: { CFEqual($0, element) }) {
            guard Date() < deadline else { return }
            _ = AXObserverRemoveNotification(observer, element, name as CFString)
        }
        registrations = registrations.filter { record in CFEqual(record.0, application) || windows.contains { CFEqual($0, record.0) } }
        for window in windows.prefix(64) {
            guard Date() < deadline else { break }
            for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                         kAXTitleChangedNotification, kAXMovedNotification, kAXResizedNotification] {
                register(window, name)
            }
        }
    }
    static func create(pid: pid_t, windows: [AXUIElement], callback: @escaping @Sendable () -> Void) -> WindowObservation? {
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            Unmanaged<AXCallback>.fromOpaque(context).takeUnretainedValue().callback()
        }, &observer) == .success, let observer else { return nil }
        let app = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passRetained(AXCallback(callback)).toOpaque()
        let observation = WindowObservation(observer: observer, application: app, context: context)
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] { observation.register(app, name) }
        observation.update(windows: windows)
        guard !observation.registrations.isEmpty else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        return observation
    }
    deinit {
        // Never perform remote removal here (deinit may run on the main actor).
        // Releasing the observer after detaching the source discards registrations.
        let retained = ObserverCleanup(observer: observer, context: context)
        DispatchQueue.main.async { retained.finish() }
    }
}
private final class ObserverCleanup: @unchecked Sendable {
    let observer: AXObserver
    let context: UnsafeMutableRawPointer
    init(observer: AXObserver, context: UnsafeMutableRawPointer) { self.observer = observer; self.context = context }
    func finish() {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        Unmanaged<AXCallback>.fromOpaque(context).release()
    }
}
