import AppKit

@MainActor final class TaskbarPanel: NSPanel {
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
@MainActor final class TaskbarView: NSView {
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
    private let insertionMarker = NSView()
    private var applicationItemPitch: CGFloat = 44
    func applyOpacity(_ opacity: Double) {
        // Tint the backing material only; text, icons and hit targets stay opaque.
        backdrop.alphaValue = opacity
    }
    init(runtime: TaskbarDelegate) {
        self.runtime = runtime; super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, buttonDragType])
        backdrop.frame = bounds; backdrop.autoresizingMask = [.width, .height]
        backdrop.material = .hudWindow; backdrop.blendingMode = .behindWindow; backdrop.state = .active
        addSubview(backdrop)
        wantsLayer = true; layer?.cornerRadius = 12; layer?.masksToBounds = true
        scroll.drawsBackground = false; scroll.documentView = content; scroll.hasHorizontalScroller = false; scroll.horizontalScrollElasticity = .allowed
        addSubview(scroll); addSubview(clock)
        insertionMarker.wantsLayer = true
        insertionMarker.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionMarker.isHidden = true
        addSubview(insertionMarker)
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
        let iconSize = min(CGFloat(44), max(CGFloat(28), 28 + (bounds.height - 40) * CGFloat(2) / CGFloat(3)))
        let buttonWidth = max(CGFloat(36), iconSize + 4)
        applicationItemPitch = max(44, buttonWidth + 4)
        for (index, value) in snapshot.buttons.enumerated() {
            let button = buttons[value.id] ?? ProcessButton(runtime: runtime)
            buttons[value.id] = button; if button.superview == nil { content.addSubview(button) }
            let targetHeight = max(36, bounds.height - 8)
            button.frame = NSRect(x: CGFloat(index) * applicationItemPitch, y: max(0, (bounds.height - 4 - targetHeight) / 2), width: buttonWidth, height: targetHeight)
            button.update(value, iconSize: iconSize)
        }
        content.setFrameSize(NSSize(width: CGFloat(snapshot.buttons.count) * applicationItemPitch, height: max(36, bounds.height - 4)))
        let format = DateFormatter(); format.dateStyle = .short; format.timeStyle = .short
        clock.stringValue = format.string(from: Date()).replacingOccurrences(of: ", ", with: "\n")
        place()
    }
    func anchor(for capture: ButtonCapture) -> NSView? { buttons[capture.button] }
    private func place() {
        let regions = PanelRegions(width: bounds.width, contentWidth: content.frame.width, height: bounds.height)
        applications.frame = regions.launcher
        controls.frame = regions.controls; clock.frame = regions.clock
        scroll.frame = regions.apps; previous.frame = regions.previous; next.frame = regions.next
        previous.isHidden = !regions.overflow; next.isHidden = !regions.overflow

    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = dragOperation(sender)
        insertionMarker.isHidden = true
        if operation == .move {
            let point = convert(sender.draggingLocation, from: nil)
            if scroll.frame.contains(point) {
                if point.x < scroll.frame.minX + 20 { move(-applicationItemPitch) }
                if point.x > scroll.frame.maxX - 20 { move(applicationItemPitch) }
                let target = content.convert(sender.draggingLocation, from: nil)
                let slot = min(runtime.coordinator.snapshot.buttons.count,
                               max(0, Int(floor((target.x + applicationItemPitch / 2) / applicationItemPitch))))
                let edge = content.convert(NSPoint(x: CGFloat(slot) * applicationItemPitch, y: 0), to: self).x
                if edge >= scroll.frame.minX && edge <= scroll.frame.maxX {
                    insertionMarker.frame = NSRect(x: edge - 1.5, y: 6, width: 3, height: max(0, bounds.height - 12))
                    insertionMarker.isHidden = false
                }
            }
        }
        return operation
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { insertionMarker.isHidden = true }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { insertionMarker.isHidden = true }
    private func dragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let source = sender.draggingSource as? ProcessButton, source.runtime === runtime,
           let capture = source.draggedButton, runtime.valid(capture) { return .move }
        return droppedURLs(sender).isEmpty ? [] : .copy
    }
    private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return !urls.isEmpty && urls.allSatisfy { $0.isFileURL && $0.pathExtension.lowercased() == "app" } ? urls : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        insertionMarker.isHidden = true
        runtime.previews.close()
        if dragOperation(sender) == .move, let source = sender.draggingSource as? ProcessButton,
           let capture = source.draggedButton {
            let point = content.convert(sender.draggingLocation, from: nil)
            let index = Int(floor((max(0, point.x) + applicationItemPitch / 2) / applicationItemPitch))
            runtime.moveButton(capture, to: index)
            return true
        }
        let urls = droppedURLs(sender)
        guard !urls.isEmpty else { return false }
        runtime.dropApplications(urls); return true
    }
    @objc private func back() { move(-applicationItemPitch * 4) }
    @objc private func forward() { move(applicationItemPitch * 4) }
    private func move(_ distance: CGFloat) {
        // Immediate scrolling respects Reduce Motion without an animation branch.
        let x = min(max(0, content.frame.width - scroll.contentSize.width), max(0, scroll.contentView.bounds.minX + distance))
        scroll.contentView.scroll(to: NSPoint(x: x, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
    }
    @objc private func showApplications() { runtime.showApplications(from: applications) }
    @objc private func showControls() { runtime.previews.menuOpening(); runtime.controlsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: controls.bounds.maxY), in: controls) }
}
private let buttonDragType = NSPasteboard.PasteboardType("app.wmac.button")

@MainActor private final class ProcessButton: NSButton, NSDraggingSource {
    unowned let runtime: TaskbarDelegate
    private var capture: ButtonCapture?
    private var iconSource: NSImage?
    private var displayedIconSize: CGFloat = 0
    private(set) var draggedButton: ButtonCapture?
    private var hoverArea: NSTrackingArea?
    init(runtime: TaskbarDelegate) {
        self.runtime = runtime; super.init(frame: .zero)
        target = self; action = #selector(pressed); imagePosition = .imageOnly; imageScaling = .scaleProportionallyDown
        bezelStyle = .regularSquare; isBordered = false; wantsLayer = true; layer?.cornerRadius = 7
        setAccessibilityRole(.button)
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: tr("Show actions", "Показать действия"), handler: { [weak self] in self?.accessibilityPerformShowMenu() ?? false })])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(hoverArea!)
    }
    override func mouseEntered(with event: NSEvent) {
        if let capture { runtime.previews.entered(self, capture: capture) }
    }
    override func mouseExited(with event: NSEvent) { runtime.previews.exited(self) }
    func update(_ value: TaskbarButton, iconSize: CGFloat) {
        capture = ButtonCapture(value)
        let source = runtime.image(value)
        if source !== iconSource || displayedIconSize != iconSize {
            let resized = source.copy() as? NSImage
            resized?.size = NSSize(width: iconSize, height: iconSize)
            image = resized; iconSource = source; displayedIconSize = iconSize
        }
        let pending = runtime.pendingCount(value.application)
        let label = (value.availability == .missing ? tr("Application not found: ", "Приложение не найдено: ") : "") + value.name + (value.ordinal.map { tr(" — instance \($0)", " — экземпляр \($0)") } ?? "") + (value.instance.map { " — PID \($0.id.pid)" } ?? "")
        let hint = label + (runtime.windowTitle(value.instance?.id).map { " — " + $0 } ?? "") + (pending > 0 ? tr(" — pending: \(pending)", " — ожидание: \(pending)") : "")
        toolTip = runtime.previews.isShowing(ButtonCapture(value)) ? nil : hint
        setAccessibilityLabel(label); setAccessibilityHelp(hint)
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
                NSBezierPath(roundedRect: NSRect(x: bounds.midX - 5, y: isFlipped ? bounds.maxY - 4 : 1, width: 10, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
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
        runtime.previews.close()
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        // Track explicitly so NSButton never dispatches a press after starting a drag.
        guard let captured = capture, let window else { return }
        var dragEvent: NSEvent?
        var released = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { released = true; break }
            if hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y) >= 5 { dragEvent = next; break }
        }
        if dragEvent != nil {
            runtime.previews.close()
            guard runtime.valid(captured) else { return }
            draggedButton = captured
            let writer = NSPasteboardItem(); writer.setString(String(describing: captured.button), forType: buttonDragType)
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
        } else if released { runtime.click(captured, new: event.modifierFlags.contains(.shift)) }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { draggedButton = nil }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 109 && event.modifierFlags.contains(.shift) { _ = accessibilityPerformShowMenu() }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformShowMenu() -> Bool {
        guard let capture else { return false }
        runtime.previews.menuOpening()
        runtime.contextMenu(capture).popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
        return true
    }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2, runtime.preferences.middleClickNewInstance, let capture { runtime.click(capture, new: true) }
    }
    override func otherMouseUp(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? {
        runtime.previews.menuOpening()
        return capture.map { runtime.contextMenu($0) }
    }
    override func rightMouseDown(with event: NSEvent) { if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) } }
}
