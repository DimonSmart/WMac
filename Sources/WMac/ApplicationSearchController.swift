import AppKit

/// One transient native popover can be anchored to any display's launcher.
@MainActor final class ApplicationSearchController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
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
        case .results: stateLabel.stringValue = state.isLoading ? tr("Refreshing…", "Обновление…") : tr("Enter to open · Right-click or Shift-F10 for actions", "Enter — открыть · Правый клик или Shift-F10 — действия")
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
        let launch = NSMenuItem(title: tr("Launch New Instance", "Запустить новый экземпляр"),
                                action: #selector(launchNewInstance(_:)), keyEquivalent: "")
        launch.target = self; launch.representedObject = menuSelection
        menu.addItem(launch)
        menu.addItem(.separator())
        let title = menuSelection.isMenuBarOnly
            ? tr("Menu-bar apps cannot be pinned", "Приложения строки меню нельзя закрепить")
            : tr("Pin", "Закрепить")
        let item = NSMenuItem(title: title, action: #selector(pinSelection), keyEquivalent: "")
        item.isEnabled = !menuSelection.isMenuBarOnly
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
    @objc private func launchNewInstance(_ sender: NSMenuItem) {
        guard let application = sender.representedObject as? CatalogApplication else { return }
        popover.performClose(nil)
        runtime.launch(application.definition, independent: true)
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
