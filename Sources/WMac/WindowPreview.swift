import AppKit
import CoreGraphics
import OSLog
@preconcurrency import ScreenCaptureKit

@MainActor
final class WindowPreviewController {
    private unowned let runtime: TaskbarDelegate
    private let thumbnails = WindowThumbnailService()
    private var panel: WindowPreviewPanel?
    private var content: WindowPreviewView?
    private weak var source: NSView?
    private var oldTooltip: String?
    private var current: ButtonCapture?
    private var hoverTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var listenerTask: Task<Void, Never>?
    private var listening: (InstanceID, UUID)?
    private var refreshRequest: UInt64 = 0
    private var generation = UUID()
    private var pointerOnButton = false
    private var pointerOnPanel = false
    private var explicitOpen = false
    private var axTemporarilyUnavailable = false

    init(runtime: TaskbarDelegate) { self.runtime = runtime }

    func entered(_ button: NSView, capture: ButtonCapture) {
        pointerOnButton = true
        closeTask?.cancel()
        if current?.button == capture.button && current?.instance == capture.instance && panel != nil { return }
        hoverTask?.cancel()
        if panel != nil { close() }
        pointerOnButton = true
        generation = UUID()
        guard capture.instance != nil, !runtime.displays.hidden,
              runtime.settings.value.hoverMode(for: capture.application) != .disabled else { return }
        source = button
        hoverTask = Task { [weak self, weak button] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, let button, self.pointerOnButton,
                  button.window != nil, !button.isHiddenOrHasHiddenAncestor else { return }
            await self.open(capture, source: button, explicit: false)
        }
    }

    func exited(_ button: NSView) {
        guard source === button else { return }
        pointerOnButton = false
        hoverTask?.cancel()
        scheduleClose()
    }

    func menuOpening() { close() }

    func openExplicit(_ capture: ButtonCapture) {
        close()
        // Defer until the native menu has stopped tracking.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            await self.open(capture, source: self.runtime.displays.anchor(for: capture), explicit: true)
        }
    }

    func reconcile() {
        thumbnails.purge(live: Set(runtime.coordinator.snapshot.buttons.compactMap { $0.instance?.id }))
        guard let current else { return }
        if (runtime.displays.hidden && !explicitOpen) || !runtime.valid(current) ||
           (source != nil && (source?.window == nil || source?.isHiddenOrHasHiddenAncestor == true)) { close() }
    }

    func settingsChanged() {
        if !runtime.settings.value.showWindowThumbnails { thumbnails.clear() }
        close()
    }
    func isShowing(_ capture: ButtonCapture) -> Bool {
        panel != nil && current?.button == capture.button && current?.instance == capture.instance
    }

    func close() {
        hoverTask?.cancel(); closeTask?.cancel(); imageTask?.cancel(); snapshotTask?.cancel()
        listenerTask?.cancel()
        listenerTask = nil
        if let listening {
            Task { await runtime.accessibility.stopListening(listening.0, token: listening.1) }
        }
        listening = nil
        hoverTask = nil; closeTask = nil; imageTask = nil; snapshotTask = nil
        refreshRequest &+= 1
        generation = UUID()
        if let button = source as? NSButton, let oldTooltip { button.toolTip = oldTooltip }
        self.oldTooltip = nil
        panel?.orderOut(nil); panel?.close()
        panel = nil; content = nil; current = nil; source = nil
        explicitOpen = false
        axTemporarilyUnavailable = false
        pointerOnPanel = false; pointerOnButton = false
    }

    private func scheduleClose() {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, !self.pointerOnButton, !self.pointerOnPanel else { return }
            self.close()
        }
    }

    private func open(_ capture: ButtonCapture, source button: NSView?, explicit: Bool) async {
        guard let id = capture.instance, runtime.valid(capture),
              (explicit || !runtime.displays.hidden) else { return }
        let token = UUID()
        generation = token
        let result = await runtime.accessibility.windows(for: id)
        guard !Task.isCancelled, generation == token, runtime.valid(capture),
              (explicit || (pointerOnButton && self.source === button)) else { return }
        let windows: [WindowReference]
        let information: String?
        switch result {
        case .windows(let values):
            windows = values
            information = values.isEmpty ? tr("No manageable windows", "Нет управляемых окон") : nil
            if !explicit && !runtime.settings.value.shouldPreview(values.count, app: capture.application) { return }
        case .unavailable:
            guard explicit else { return }
            windows = []
            information = tr("Accessibility is required to enumerate windows.", "Для списка окон нужен Универсальный доступ.")
        }

        let target = runtime.coordinator.snapshot.buttons.first(where: { $0.id == capture.button })
        let name = (target?.name ?? tr("Application", "Приложение")) +
            (target?.ordinal.map { tr(" — instance \($0)", " — экземпляр \($0)") } ?? "")
        let view = WindowPreviewView(name: name, windows: windows, information: information)
        view.onSelect = { [weak self] window in self?.select(window, capture: capture) }
        view.onRefresh = { [weak self] in self?.openExplicit(capture) }
        view.onEnter = { [weak self] in self?.pointerOnPanel = true; self?.closeTask?.cancel() }
        view.onExit = { [weak self] in self?.pointerOnPanel = false; self?.scheduleClose() }
        view.onPermission = { [weak self] in
            guard let self else { return }
            if !self.runtime.permissions.trusted { self.runtime.requestPermission() }
            else { self.runtime.requestScreenRecording() }
        }
        if !CGPreflightScreenCaptureAccess() { thumbnails.clear() }
        if information != nil || !runtime.settings.value.showWindowThumbnails || !CGPreflightScreenCaptureAccess() {
            view.setPermissionHint(allowImages: runtime.settings.value.showWindowThumbnails, axTrusted: runtime.permissions.trusted)
        }

        let destination = place(size: view.frame.size, near: button)
        let popup = WindowPreviewPanel(contentRect: destination)
        popup.contentView = view
        popup.onEscape = { [weak self] in self?.close() }
        popup.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        popup.appearance = runtime.settings.value.theme == .system ? nil : NSAppearance(named: runtime.settings.value.theme == .dark ? .darkAqua : .aqua)
        source = button
        if let button = button as? NSButton {
            oldTooltip = button.toolTip
            button.toolTip = nil
        }
        current = capture
        axTemporarilyUnavailable = information != nil
        explicitOpen = explicit
        panel = popup; content = view
        popup.orderFront(nil)
        if explicit {
            NSApp.activate()
            popup.makeKey()
            if let first = view.cards.first { popup.makeFirstResponder(first) }
        }

        startImages(windows, instance: id, capture: capture, token: token)
        if panel != nil {
            listenerTask = Task { [weak self] in
                guard let self else { return }
                let listenerID = await self.runtime.accessibility.listen(id) { [weak self] in
                    Task { @MainActor [weak self] in self?.scheduleRefresh(instance: id, capture: capture) }
                }
                if Task.isCancelled || self.panel == nil || self.current?.instance != id {
                    await self.runtime.accessibility.stopListening(id, token: listenerID)
                    return
                }
                self.listening = (id, listenerID)
            }
            snapshotTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self, self.current?.instance == id,
                          self.runtime.valid(capture), self.panel != nil else { return }
                    self.scheduleRefresh(instance: id, capture: capture)
                }
            }
        }
    }

    private func scheduleRefresh(instance id: InstanceID, capture: ButtonCapture) {
        guard current?.instance == id, panel != nil, runtime.valid(capture) else { return }
        refreshRequest &+= 1
        let request = refreshRequest
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            let latest = await self.runtime.accessibility.windows(for: id)
            guard !Task.isCancelled, self.refreshRequest == request, self.generation == token,
                  self.panel != nil, self.current?.instance == id, self.runtime.valid(capture) else { return }
            if !CGPreflightScreenCaptureAccess() {
                self.thumbnails.clear()
                self.imageTask?.cancel()
                self.content?.clearImages()
                self.content?.setPermissionHint(allowImages: self.runtime.settings.value.showWindowThumbnails,
                                                axTrusted: self.runtime.permissions.trusted)
            }
            switch latest {
            case .unavailable:
                if !self.axTemporarilyUnavailable {
                    self.axTemporarilyUnavailable = true
                    self.generation = UUID()
                    self.imageTask?.cancel()
                    self.thumbnails.clear()
                    self.content?.clearImages()
                    self.content?.setDataUnavailable(true)
                }
            case .windows(let updated):
                let recovered = self.axTemporarilyUnavailable
                self.axTemporarilyUnavailable = false
                if let view = self.content {
                    let changed = view.reconcile(updated)
                    view.setDataUnavailable(false)
                    view.setPermissionHint(allowImages: self.runtime.settings.value.showWindowThumbnails,
                                           axTrusted: self.runtime.permissions.trusted)
                    if changed || recovered {
                        self.generation = UUID()
                        self.imageTask?.cancel()
                        self.thumbnails.clear()
                        self.startImages(updated, instance: id, capture: capture, token: self.generation)
                    }
                }
            }
        }
    }

    private func startImages(_ windows: [WindowReference], instance: InstanceID, capture: ButtonCapture, token: UUID) {
        guard !windows.isEmpty, runtime.settings.value.showWindowThumbnails, CGPreflightScreenCaptureAccess() else { return }
        imageTask?.cancel()
        imageTask = Task { [weak self] in
            guard let self else { return }
            await self.thumbnails.load(windows, instance: instance, accessibility: self.runtime.accessibility,
                                       stillCurrent: { [weak self] in
                guard let self else { return false }
                return self.generation == token && self.panel != nil && self.runtime.valid(capture)
            }, onImage: { [weak self] reference, image, cached in
                guard let self, self.generation == token else { return }
                self.content?.update(window: reference, image: image, cached: cached)
            })
        }
    }

    private func select(_ window: WindowReference, capture: ButtonCapture) {
        close()
        Task { @MainActor [weak self] in
            guard let self, self.runtime.valid(capture), capture.instance == window.instance else { return }
            let result = await self.runtime.accessibility.select(window)
            if result.outcome != .restored {
                self.runtime.notify(tr("Window unavailable", "Окно недоступно"), result.message)
            }
        }
    }

    private func place(size: NSSize, near button: NSView?) -> NSRect {
        if let button, let window = button.window {
            let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = window.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(buttonRect) }) ?? NSScreen.main
            let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
            let margin: CGFloat = 8
            let gap: CGFloat = 8
            let width = min(size.width, max(1, bounds.width - 20))
            let y = buttonRect.maxY + gap
            let height = min(size.height, max(0, bounds.maxY - margin - y))
            let x = max(bounds.minX + 10, min(buttonRect.midX - width / 2, bounds.maxX - width - 10))
            return NSRect(x: x, y: y, width: width, height: height)
        }
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let width = min(size.width, max(260, bounds.width - 20))
        let height = min(size.height, max(180, bounds.height - 20))
        let x = max(bounds.minX + 10, min(point.x - width / 2, bounds.maxX - width - 10))
        let above = point.y + 12
        let y = above + height < bounds.maxY - 8 ? above : max(bounds.minY + 8, point.y - height - 48)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
private final class WindowPreviewPanel: NSPanel {
    var onEscape: (() -> Void)?
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        if event.keyCode == 123 || event.keyCode == 126 {
            (contentView as? WindowPreviewView)?.focus(direction: -1, in: self)
            return
        }
        if event.keyCode == 124 || event.keyCode == 125 {
            (contentView as? WindowPreviewView)?.focus(direction: 1, in: self)
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class WindowPreviewCard: NSButton {
    private(set) var windowReference: WindowReference
    private let picture = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let stateField = NSTextField(labelWithString: "")
    var choose: ((WindowReference) -> Void)?
    init(_ reference: WindowReference) {
        windowReference = reference
        super.init(frame: NSRect(x: 0, y: 0, width: 232, height: 190))
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = (reference.isFocused ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22) : NSColor.controlBackgroundColor).cgColor
        picture.frame = NSRect(x: 6, y: 44, width: 220, height: 140)
        picture.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.toolTip = tr("Thumbnail unavailable", "Миниатюра недоступна")
        titleField.frame = NSRect(x: 8, y: 22, width: 216, height: 20)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.stringValue = reference.title
        stateField.frame = NSRect(x: 8, y: 3, width: 216, height: 17)
        stateField.font = .systemFont(ofSize: 11)
        stateField.textColor = .secondaryLabelColor
        stateField.stringValue = reference.isMinimized ? tr("Minimized", "Свёрнуто") : (reference.isFocused ? tr("Active", "Активно") : "")
        for view in [picture, titleField, stateField] { addSubview(view) }
        toolTip = reference.title
        setAccessibilityLabel(reference.title + (reference.isMinimized ? tr(", minimized", ", свёрнуто") : "") + (reference.isFocused ? tr(", active", ", активно") : ""))
        setAccessibilityRole(.button)
        target = self; action = #selector(pick)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func pick() { choose?(windowReference) }
    func update(_ reference: WindowReference) {
        if reference.captureState != windowReference.captureState {
            picture.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        }
        windowReference = reference
        titleField.stringValue = reference.title
        toolTip = reference.title
        setAccessibilityLabel(reference.title + (reference.isMinimized ? tr(", minimized", ", свёрнуто") : "") +
                              (reference.isFocused ? tr(", active", ", активно") : ""))
        layer?.backgroundColor = (reference.isFocused ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22) : NSColor.controlBackgroundColor).cgColor
        stateField.stringValue = reference.isMinimized ? tr("Minimized", "Свёрнуто") : (reference.isFocused ? tr("Active", "Активно") : "")
    }
    func clearImage() {
        picture.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        picture.toolTip = tr("Thumbnail unavailable", "Миниатюра недоступна")
        stateField.stringValue = windowReference.isMinimized ? tr("Minimized", "Свёрнуто") : (windowReference.isFocused ? tr("Active", "Активно") : "")
    }
    func show(_ image: NSImage, cached: Bool) {
        picture.image = image
        picture.toolTip = cached ? tr("Previously captured frame", "Предыдущий снимок") : nil
        if cached { stateField.stringValue = tr("Previous frame", "Предыдущий кадр") }
        else { stateField.stringValue = windowReference.isMinimized ? tr("Minimized", "Свёрнуто") : (windowReference.isFocused ? tr("Active", "Активно") : "") }
    }
}

@MainActor
private final class WindowPreviewView: NSView {
    private let header = NSTextField(labelWithString: "")
    private let name: String
    private let info = NSTextField(labelWithString: "")
    private let permission = NSButton(title: "", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let strip = NSView()
    private(set) var cards: [WindowPreviewCard] = []
    var onSelect: ((WindowReference) -> Void)?
    var onRefresh: (() -> Void)?
    var onPermission: (() -> Void)?
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var area: NSTrackingArea?

    init(name: String, windows: [WindowReference], information: String?) {
        self.name = name
        let width = CGFloat(min(3, max(1, windows.count))) * 240 + 16
        super.init(frame: NSRect(x: 0, y: 0, width: max(280, width), height: 278))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let backdrop = NSVisualEffectView(frame: bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 12
        backdrop.layer?.masksToBounds = true
        backdrop.material = .popover
        backdrop.state = .active
        addSubview(backdrop)
        header.frame = NSRect(x: 12, y: 245, width: max(210, bounds.width - 98), height: 22)
        header.stringValue = name + " — " + String(windows.count)
        header.font = .boldSystemFont(ofSize: 13)
        addSubview(header)
        let reload = NSButton(title: tr("Refresh", "Обновить"), target: self, action: #selector(refresh))
        reload.frame = NSRect(x: bounds.width - 78, y: 241, width: 70, height: 29)
        reload.autoresizingMask = [.minXMargin]
        addSubview(reload)
        scroll.frame = NSRect(x: 8, y: 38, width: bounds.width - 16, height: 198)
        scroll.autoresizingMask = [.width]
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.documentView = strip
        addSubview(scroll)
        strip.frame = NSRect(x: 0, y: 0, width: CGFloat(max(windows.count, 1)) * 240, height: 198)
        for (index, window) in windows.enumerated() {
            let card = WindowPreviewCard(window)
            card.frame.origin = NSPoint(x: CGFloat(index) * 240 + 4, y: 4)
            card.choose = { [weak self] value in self?.onSelect?(value) }
            strip.addSubview(card); cards.append(card)
        }
        info.frame = NSRect(x: 10, y: 7, width: bounds.width - 18, height: 24)
        info.autoresizingMask = [.width]
        info.font = .systemFont(ofSize: 12)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingTail
        info.stringValue = information ?? ""
        addSubview(info)
        permission.frame = NSRect(x: 8, y: 6, width: bounds.width - 16, height: 28)
        permission.autoresizingMask = [.width]
        permission.target = self; permission.action = #selector(permit)
        permission.isHidden = true
        addSubview(permission)
    }
    required init?(coder: NSCoder) { fatalError() }
    func setPermissionHint(allowImages: Bool, axTrusted: Bool) {
        permission.isHidden = true
        if !axTrusted {
            permission.title = tr("Enable Accessibility…", "Включить Универсальный доступ…")
        } else if allowImages && !CGPreflightScreenCaptureAccess() {
            permission.title = tr("Allow window thumbnails…", "Разрешить миниатюры окон…")
        } else { return }
        permission.isHidden = false
    }
    /// Returns true when a fresh thumbnail association is required.
    @discardableResult func reconcile(_ windows: [WindowReference]) -> Bool {
        let oldIDs = Set(cards.map { $0.windowReference.id })
        let updatedByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let updatedIDs = Set(windows.map(\.id))
        let staleAssociation = oldIDs != updatedIDs || cards.contains { card in
            guard let current = updatedByID[card.windowReference.id] else { return true }
            return current.captureState != card.windowReference.captureState
        }
        for card in cards where !updatedIDs.contains(card.windowReference.id) { card.removeFromSuperview() }
        cards.removeAll { !updatedIDs.contains($0.windowReference.id) }
        for card in cards {
            if let latest = updatedByID[card.windowReference.id] { card.update(latest) }
        }
        for window in windows where !cards.contains(where: { $0.windowReference.id == window.id }) {
            let card = WindowPreviewCard(window)
            card.choose = { [weak self] value in self?.onSelect?(value) }
            strip.addSubview(card); cards.append(card)
        }
        for (index, card) in cards.enumerated() { card.frame.origin = NSPoint(x: CGFloat(index) * 240 + 4, y: 4) }
        strip.setFrameSize(NSSize(width: CGFloat(max(cards.count, 1)) * 240, height: 198))
        header.stringValue = name + " — " + String(cards.count)
        info.stringValue = cards.isEmpty ? tr("No manageable windows", "Нет управляемых окон") : ""
        return staleAssociation
    }
    func focus(direction: Int, in panel: NSWindow) {
        guard !cards.isEmpty else { return }
        let index = cards.firstIndex(where: { $0 === panel.firstResponder }) ?? (direction > 0 ? -1 : cards.count)
        let next = max(0, min(cards.count - 1, index + direction))
        let card = cards[next]
        panel.makeFirstResponder(card)
        card.scrollToVisible(card.bounds)
    }
    func clearImages() { for card in cards { card.clearImage() } }
    func setDataUnavailable(_ unavailable: Bool) {
        info.stringValue = unavailable ? tr("Window data temporarily unavailable; retrying…", "Данные окон временно недоступны; повторяем…") :
            (cards.isEmpty ? tr("No manageable windows", "Нет управляемых окон") : "")
    }
    func update(window reference: WindowReference, image: NSImage, cached: Bool) {
        guard let card = cards.first(where: { $0.windowReference.identity == reference.identity }),
              card.windowReference.captureState == reference.captureState else { return }
        card.show(image, cached: cached)
    }
    @objc private func refresh() { onRefresh?() }
    @objc private func permit() { onPermission?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area!)
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

@MainActor
private final class WindowThumbnailService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.wmac.WMac", category: "WindowPreviews")
    private let diagnosticsEnabled = ProcessInfo.processInfo.arguments.contains("--window-diagnostics") ||
        ProcessInfo.processInfo.environment["WMAC_WINDOW_DIAGNOSTICS"] == "1"
    private let diagnosticTitlesEnabled = ProcessInfo.processInfo.environment["WMAC_WINDOW_DIAGNOSTICS_TITLES"] == "1"
    private struct Key: Hashable {
        let identity: WindowIdentity
        let revision: UInt64
        let graphics: CGWindowID
        let frame: [Int]
    }
    private struct Entry { let image: NSImage; let date: Date; let bytes: Int }
    private var cache: [Key: Entry] = [:]
    private var activeCaptures = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func diagnose(_ code: String, window: WindowReference? = nil,
                          candidates: [CGWindowID] = [], detail: String = "") {
        guard diagnosticsEnabled else { return }
        let identity = window.map {
            let frame = $0.frame.map { "(\($0.minX),\($0.minY),\($0.width),\($0.height))" } ?? "unknown"
            let title = diagnosticTitlesEnabled ? $0.title : "<redacted>"
            return "pid=\($0.instance.pid) start=\($0.instance.startDate.timeIntervalSince1970) ax=\($0.id) lifecycle=\($0.lifecycle) revision=\($0.stateRevision) role=\($0.role ?? "?") subrole=\($0.subrole ?? "?") title=\(title) frame=\(frame) minimized=\($0.isMinimized)"
        } ?? ""
        logger.info("windowIdentity code=\(code, privacy: .public) \(identity, privacy: .public) candidates=\(String(describing: candidates), privacy: .public) \(detail, privacy: .public)")
    }

    private func acquire() async {
        if activeCaptures < 2 { activeCaptures += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    private func release() {
        if waiting.isEmpty { activeCaptures -= 1 }
        else { waiting.removeFirst().resume() }
    }
    func clear() {
        if !cache.isEmpty { diagnose("cacheInvalidated", detail: "reason=explicitOrUnavailable") }
        cache.removeAll()
    }
    func purge(live: Set<InstanceID>) {
        cache = cache.filter { live.contains($0.key.identity.instance) }
    }

    private func processIsCurrent(_ instance: InstanceID) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: instance.pid), !app.isTerminated else { return false }
        return ProcessLifetime.startDate(for: app) == instance.startDate
    }

    private func graphics(for instance: InstanceID, from available: [SCWindow]) async -> [GraphicalWindow] {
        // AXPosition and kCGWindowBounds share global top-left screen coordinates;
        // SCWindow.frame is not used for matching (particularly on secondary displays).
        let bounds = await Task.detached(priority: .utility) {
            Self.globalWindowBounds(processID: instance.pid)
        }.value
        return available.compactMap { source in
            guard let frame = bounds[source.windowID] else { return nil }
            return GraphicalWindow(id: source.windowID, title: source.title ?? "", frame: frame,
                                   processID: source.owningApplication?.processID)
        }
    }

    // Every asynchronous result, including a cache hit, requires a *fresh* AX
    // read and a fresh graphical candidate set. A timeout is NOT an empty set.
    // There is no suspension between the final check and publishing the image.
    private func currentlyConfirmed(_ resolution: GraphicsResolution, graphicsID: CGWindowID,
                                    baseline: [WindowReference], instance: InstanceID,
                                    accessibility: AccessibilityService,
                                    stillCurrent: @MainActor () -> Bool) async -> Bool {
        guard stillCurrent(), !Task.isCancelled, processIsCurrent(instance),
              CGPreflightScreenCaptureAccess() else { return false }
        let refreshed = await accessibility.windows(for: instance)
        guard case .windows(let latest) = refreshed, latest.count == baseline.count,
              Set(latest.map(\.identity)) == Set(baseline.map(\.identity)),
              latest.allSatisfy({ now in baseline.contains { $0.captureState == now.captureState } }),
              let current = latest.first(where: { $0.identity == resolution.identity }),
              current.stateRevision == resolution.observedRevision else {
            diagnose("staleAXState", window: baseline.first(where: { $0.identity == resolution.identity }))
            return false
        }
        let updatedGraphics: [SCWindow]
        do {
            updatedGraphics = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                .windows.filter { $0.owningApplication?.processID == instance.pid }
        } catch {
            diagnose("graphicsEnumerationUnavailable", window: current)
            return false
        }
        guard stillCurrent(), !Task.isCancelled, processIsCurrent(instance) else { return false }
        let geometry = await graphics(for: instance, from: updatedGraphics)
        let latestMatches = WindowMatcher.resolve(latest, to: geometry)
        guard let decision = latestMatches[current.id],
              decision.identity == resolution.identity,
              decision.observedRevision == resolution.observedRevision,
              decision.status == .confirmedGraphicsMatch(graphicsID),
              updatedGraphics.contains(where: { $0.windowID == graphicsID }),
              stillCurrent(), !Task.isCancelled, processIsCurrent(instance) else {
            diagnose("graphicsMatchChanged", window: current, candidates: [graphicsID])
            return false
        }
        return CGPreflightScreenCaptureAccess()
    }

    func load(_ windows: [WindowReference], instance: InstanceID,
              accessibility: AccessibilityService,
              stillCurrent: @escaping @MainActor () -> Bool,
              onImage: @escaping @MainActor (WindowReference, NSImage, Bool) -> Void) async {
        guard CGPreflightScreenCaptureAccess() else {
            diagnose("screenRecordingPermissionMissing", detail: "pid=\(instance.pid)")
            return
        }
        guard stillCurrent(), processIsCurrent(instance) else { return }
        let started = Date()
        let available: [SCWindow]
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            available = content.windows.filter { $0.owningApplication?.processID == instance.pid }
        } catch {
            logger.error("ScreenCaptureKit window enumeration failed for process \(instance.pid): \(error.localizedDescription, privacy: .private)")
            for window in windows { diagnose("graphicsEnumerationUnavailable", window: window) }
            return
        }
        guard stillCurrent(), processIsCurrent(instance) else { return }
        let geometry = await graphics(for: instance, from: available)
        let resolutions = WindowMatcher.resolve(windows, to: geometry)
        diagnose("resolutionCompleted", detail: "pid=\(instance.pid) windows=\(windows.count) graphics=\(geometry.count) elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")

        for window in windows {
            guard !Task.isCancelled, stillCurrent(), processIsCurrent(instance) else { return }
            guard let decision = resolutions[window.id],
                  decision.identity == window.identity,
                  decision.observedRevision == window.stateRevision else { continue }
            diagnose(decision.reason.rawValue, window: window, candidates: decision.candidateIDs,
                     detail: "outcome=\(String(describing: decision.status)) association=\(decision.associationGeneration)")
            guard case .confirmedGraphicsMatch(let graphicsID) = decision.status,
                  let source = available.first(where: { $0.windowID == graphicsID }) else { continue }

            let frame = geometry.first(where: { $0.id == graphicsID })?.frame ?? source.frame
            let key = Key(identity: window.identity, revision: window.stateRevision, graphics: graphicsID,
                          frame: [Int(frame.minX.rounded()), Int(frame.minY.rounded()),
                                  Int(frame.width.rounded()), Int(frame.height.rounded())])
            if let saved = cache[key], Date().timeIntervalSince(saved.date) < 10 {
                if await currentlyConfirmed(decision, graphicsID: graphicsID, baseline: windows,
                                            instance: instance, accessibility: accessibility, stillCurrent: stillCurrent) {
                    diagnose("captureCacheHit", window: window, candidates: [graphicsID])
                    onImage(window, saved.image, true)
                } else {
                    cache.removeValue(forKey: key)
                    continue
                }
            }
            guard stillCurrent(), !Task.isCancelled, processIsCurrent(instance) else { return }
            let config = SCStreamConfiguration()
            let scale = min(440 / max(source.frame.width, 1), 280 / max(source.frame.height, 1), 1)
            config.width = max(1, Int(source.frame.width * scale))
            config.height = max(1, Int(source.frame.height * scale))
            await acquire()
            guard stillCurrent(), !Task.isCancelled, processIsCurrent(instance) else { release(); return }
            let captureStarted = Date()
            diagnose("captureStarted", window: window, candidates: [graphicsID])
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: source), configuration: config)
                release()
                guard await currentlyConfirmed(decision, graphicsID: graphicsID, baseline: windows,
                                               instance: instance, accessibility: accessibility, stillCurrent: stillCurrent) else {
                    diagnose("captureDiscardedStale", window: window, candidates: [graphicsID])
                    continue
                }
                let picture = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height)))
                let bytes = image.width * image.height * 4
                cache[key] = Entry(image: picture, date: Date(), bytes: bytes)
                trim()
                diagnose("captureSucceeded", window: window, candidates: [graphicsID],
                         detail: "elapsedMs=\(Int(Date().timeIntervalSince(captureStarted) * 1000))")
                onImage(window, picture, false)
            } catch {
                release()
                logger.error("ScreenCaptureKit capture failed for process \(instance.pid), AX window \(window.id.uuidString, privacy: .public), graphics window \(graphicsID): \(error.localizedDescription, privacy: .private)")
                diagnose("captureFailed", window: window, candidates: [graphicsID],
                         detail: "elapsedMs=\(Int(Date().timeIntervalSince(captureStarted) * 1000))")
            }
        }
    }

    private nonisolated static func globalWindowBounds(processID: pid_t) -> [CGWindowID: CGRect] {
        guard let entries = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var boundsByID: [CGWindowID: CGRect] = [:]
        for entry in entries {
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let dictionary = entry[kCGWindowBounds as String] as? NSDictionary else { continue }
            var frame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(dictionary as CFDictionary, &frame),
                  frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { continue }
            boundsByID[CGWindowID(number.uint32Value)] = frame
        }
        return boundsByID
    }

    private func trim() {
        var remaining = cache.values.reduce(0) { $0 + $1.bytes }
        for (key, entry) in cache.sorted(by: { $0.value.date < $1.value.date }) where remaining > 32 * 1024 * 1024 {
            cache.removeValue(forKey: key)
            remaining -= entry.bytes
        }
    }
}
