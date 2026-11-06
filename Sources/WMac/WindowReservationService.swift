import AppKit
import ApplicationServices

extension WindowReservationDisplay {
    @MainActor static func current(settings: WMacSettings, panelsHidden: Bool) -> [Self] {
        guard !panelsHidden else { return [] }
        let screens = NSScreen.screens
        guard let primary = screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }) ?? screens.first else { return [] }
        let primaryTop = primary.frame.maxY
        func ax(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
        }
        return screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  settings.allDisplays || id == CGMainDisplayID() else { return nil }
            let visible = screen.visibleFrame
            let panelTop = screen.frame.minY + 8 + CGFloat(settings.height)
            let reservedBottom = max(visible.minY, panelTop + 4)
            guard reservedBottom < visible.maxY else { return nil }
            let available = CGRect(x: visible.minX, y: reservedBottom,
                                   width: visible.width, height: visible.maxY - reservedBottom)
            return Self(id: id, frame: ax(screen.frame), visible: ax(visible),
                        available: ax(available), appKitAvailable: available)
        }
    }
}

@MainActor
final class WindowReservationService {
    private struct ManagedWindow {
        let identity: WindowIdentity
        let original: CGRect
        let adjusted: CGRect
    }

    private let accessibility: AccessibilityService
    private var active = false
    private var reconciling = false
    private var displays: [WindowReservationDisplay] = []
    private var tracked: [WindowIdentity: ManagedWindow] = [:]
    private var observedInstance: InstanceID?
    private var observationToken: UUID?
    private var observationTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var evaluationInProgress = false
    private var generation: UInt64 = 0
    private var activationObserver: NSObjectProtocol?

    init(accessibility: AccessibilityService) {
        self.accessibility = accessibility
    }

    func start() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.watchFrontmost() }
        }
    }

    func workArea(for screen: NSScreen) -> CGRect {
        guard active,
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let display = displays.first(where: { $0.id == id }) else { return screen.visibleFrame }
        return display.appKitAvailable
    }

    func configure(settings: WMacSettings, panelsHidden: Bool) {
        let nextDisplays = WindowReservationDisplay.current(settings: settings, panelsHidden: panelsHidden)
        let nextActive = settings.reserveTaskbarSpace && !nextDisplays.isEmpty
        guard active != nextActive || displays != nextDisplays else { return }
        active = nextActive
        displays = nextDisplays
        reconciling = true
        generation &+= 1
        evaluationTask?.cancel()
        if !active { unwatch() }
        let revision = generation
        Task { [weak self] in
            guard let self else { return }
            await self.restoreManagedWindows()
            guard self.generation == revision else { return }
            self.reconciling = false
            if self.active { self.watchFrontmost() }
        }
    }

    private func unwatch() {
        observationTask?.cancel()
        observationTask = nil
        if let token = observationToken, let instance = observedInstance {
            Task { [accessibility] in await accessibility.stopListening(instance, token: token) }
        }
        observationToken = nil
        observedInstance = nil
    }

    private func watchFrontmost() {
        guard active, !reconciling, accessibility.trusted else { unwatch(); return }
        let application = NSWorkspace.shared.frontmostApplication
        let next: InstanceID?
        if let application,
           application.processIdentifier != getpid(),
           application.activationPolicy == .regular,
           let start = ProcessLifetime.startDate(for: application) {
            next = InstanceID(pid: application.processIdentifier, startDate: start)
        } else {
            next = nil
        }
        if next != observedInstance {
            unwatch()
            observedInstance = next
            generation &+= 1
            guard let next else { return }
            let revision = generation
            observationTask = Task { [weak self] in
                guard let self else { return }
                let token = await self.accessibility.listen(next) { [weak self] in
                    Task { @MainActor [weak self] in self?.scheduleEvaluation() }
                }
                guard !Task.isCancelled, self.active, self.generation == revision,
                      self.observedInstance == next else {
                    await self.accessibility.stopListening(next, token: token)
                    return
                }
                self.observationToken = token
                _ = await self.accessibility.windows(for: next)
                self.scheduleEvaluation()
            }
        } else {
            scheduleEvaluation()
        }
    }

    private func scheduleEvaluation() {
        guard active, !reconciling, observedInstance != nil else { return }
        evaluationTask?.cancel()
        evaluationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(170))
            guard !Task.isCancelled else { return }
            await self?.evaluate()
        }
    }

    private func evaluate() async {
        guard active, !reconciling, !evaluationInProgress,
              let instance = observedInstance else { return }
        evaluationInProgress = true
        defer { evaluationInProgress = false }
        let revision = generation
        guard case .windows(let windows, _) = await accessibility.windows(for: instance),
              revision == generation, active, !reconciling,
              let window = windows.first(where: { $0.isFocused && !$0.isMinimized &&
                  $0.role == kAXWindowRole as String &&
                  ($0.subrole == nil || $0.subrole == kAXStandardWindowSubrole as String) }),
              let current = window.frame else { return }

        if let managed = tracked[window.identity] {
            if WindowReservationGeometry.approximatelyEqual(current, managed.adjusted) { return }
            // The user or the application changed the geometry; never restore stale coordinates.
            tracked.removeValue(forKey: window.identity)
        }
        guard let display = WindowReservationGeometry.bestDisplay(for: current, in: displays),
              let target = WindowReservationGeometry.adjustedFrame(
                current, visible: display.visible, full: display.frame, available: display.available
              ) else { return }

        let changed = await accessibility.arrangeReservation(
            instance, windowID: window.id, expected: current, target: target
        )
        guard changed else { return }
        let managed = ManagedWindow(identity: window.identity, original: current, adjusted: target)
        tracked[window.identity] = managed
        if tracked.count > 256, let stale = tracked.keys.first(where: { $0 != window.identity }) { tracked.removeValue(forKey: stale) }
        if revision != generation || observedInstance != instance || !active || reconciling {
            _ = await accessibility.arrangeReservation(
                instance, windowID: window.id, expected: target, target: current
            )
            tracked.removeValue(forKey: window.identity)
        }
    }

    private func restoreManagedWindows() async {
        let originals = Array(tracked.values)
        tracked.removeAll()
        for managed in originals {
            _ = await accessibility.arrangeReservation(
                managed.identity.instance,
                windowID: managed.identity.axID,
                expected: managed.adjusted,
                target: managed.original
            )
        }
    }

    func stop() async {
        active = false
        reconciling = true
        generation &+= 1
        evaluationTask?.cancel()
        unwatch()
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
        await restoreManagedWindows()
    }
}
