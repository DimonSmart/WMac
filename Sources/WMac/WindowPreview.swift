import AppKit
import CoreGraphics
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
    private var generation = UUID()
    private var pointerOnButton = false
    private var pointerOnPanel = false

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
        guard let current else { return }
        if runtime.displays.hidden || !runtime.valid(current) ||
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
        hoverTask?.cancel(); closeTask?.cancel(); imageTask?.cancel()
        hoverTask = nil; closeTask = nil; imageTask = nil
        generation = UUID()
        if let button = source as? NSButton, let oldTooltip { button.toolTip = oldTooltip }
        self.oldTooltip = nil
        panel?.orderOut(nil); panel?.close()
        panel = nil; content = nil; current = nil; source = nil
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
        guard let id = capture.instance, runtime.valid(capture), !runtime.displays.hidden else { return }
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

        let name = runtime.coordinator.snapshot.buttons.first(where: { $0.id == capture.button })?.name ?? tr("Application", "Приложение")
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
        panel = popup; content = view
        popup.orderFront(nil)
        if explicit {
            NSApp.activate()
            popup.makeKey()
            if let first = view.cards.first { popup.makeFirstResponder(first) }
        }

        if !windows.isEmpty && runtime.settings.value.showWindowThumbnails && CGPreflightScreenCaptureAccess() {
            imageTask = Task { [weak self] in
                guard let self else { return }
                await self.thumbnails.load(windows, instance: id, stillCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.generation == token && self.panel != nil && self.runtime.valid(capture)
                }, onImage: { [weak self] windowID, image, cached in
                    guard let self, self.generation == token else { return }
                    self.content?.update(windowID: windowID, image: image, cached: cached)
                })
            }
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
        var point = NSEvent.mouseLocation
        if let button, let window = button.window {
            let top = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.maxY), to: nil)
            point = window.convertPoint(toScreen: top)
        }
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
        backgroundColor = .windowBackgroundColor
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
private final class WindowPreviewCard: NSButton {
    let windowReference: WindowReference
    private let picture = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let stateField = NSTextField(labelWithString: "")
    var choose: ((WindowReference) -> Void)?
    init(_ reference: WindowReference) {
        windowReference = reference
        super.init(frame: NSRect(x: 0, y: 0, width: 232, height: 190))
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
        let width = CGFloat(min(3, max(1, windows.count))) * 240 + 16
        super.init(frame: NSRect(x: 0, y: 0, width: max(280, width), height: 278))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        let backdrop = NSVisualEffectView(frame: bounds)
        backdrop.autoresizingMask = [.width, .height]
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
        if !axTrusted {
            permission.title = tr("Enable Accessibility…", "Включить Универсальный доступ…")
        } else if allowImages && !CGPreflightScreenCaptureAccess() {
            permission.title = tr("Allow window thumbnails…", "Разрешить миниатюры окон…")
        } else { return }
        permission.isHidden = false
    }
    func update(windowID: UUID, image: NSImage, cached: Bool) {
        cards.first(where: { $0.windowReference.id == windowID })?.show(image, cached: cached)
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
    private struct Key: Hashable { let instance: InstanceID; let window: UUID; let graphics: CGWindowID }
    private struct Entry { let image: NSImage; let date: Date; let bytes: Int }
    private var cache: [Key: Entry] = [:]
    func clear() { cache.removeAll() }

    func load(_ windows: [WindowReference], instance: InstanceID,
              stillCurrent: @escaping @MainActor () -> Bool,
              onImage: @escaping @MainActor (UUID, NSImage, Bool) -> Void) async {
        guard CGPreflightScreenCaptureAccess(), stillCurrent() else { return }
        let available: [SCWindow]
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            available = content.windows.filter { $0.owningApplication?.processID == instance.pid }
        } catch { return }

        let geometry = available.map { GraphicalWindow(id: $0.windowID, title: $0.title ?? "", frame: $0.frame) }
        let associations = WindowMatcher.match(windows, to: geometry)
        for window in windows {
            guard !Task.isCancelled, stillCurrent() else { return }
            guard case .matched(let graphicsID) = associations[window.id],
                  let source = available.first(where: { $0.windowID == graphicsID }) else { continue }
            let key = Key(instance: instance, window: window.id, graphics: graphicsID)
            if let saved = cache[key], Date().timeIntervalSince(saved.date) < 10 {
                onImage(window.id, saved.image, true)
            }
            guard stillCurrent(), !Task.isCancelled else { return }
            let config = SCStreamConfiguration()
            let scale = min(440 / max(source.frame.width, 1), 280 / max(source.frame.height, 1), 1)
            config.width = max(1, Int(source.frame.width * scale))
            config.height = max(1, Int(source.frame.height * scale))
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: source), configuration: config)
                guard stillCurrent(), !Task.isCancelled else { return }
                let picture = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height)))
                let bytes = image.width * image.height * 4
                cache[key] = Entry(image: picture, date: Date(), bytes: bytes)
                trim()
                onImage(window.id, picture, false)
            } catch {
                // A protected, minimized or non-capturable window retains its AX card.
                continue
            }
        }
    }

    private func trim() {
        var remaining = cache.values.reduce(0) { $0 + $1.bytes }
        for (key, entry) in cache.sorted(by: { $0.value.date < $1.value.date }) where remaining > 32 * 1024 * 1024 {
            cache.removeValue(forKey: key)
            remaining -= entry.bytes
        }
    }
}
