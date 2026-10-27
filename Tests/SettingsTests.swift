import Foundation

@MainActor func testSettings(_ check: (Bool, String) -> Void) async throws {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("WMacSettings-\(UUID())")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    let url = folder.appendingPathComponent("settings.json")
    let store = SettingsStore(url: url)
    check(try await store.load() == WMacSettings(), "missing settings use sensible defaults")
    var value = WMacSettings(); value.theme = .dark; value.height = 40; value.opacity = 0.35; value.middleClick = false
    let a = AppDefinition(url: URL(fileURLWithPath: "/Applications/A.app"), bundleID: "a")
    let b = AppDefinition(url: URL(fileURLWithPath: "/Applications/B.app"), bundleID: "a")
    value.exclusions = [a]; value.dockGuidanceSeen = true
    try await store.save(value)
    check(try await SettingsStore(url: url).load() == value, "settings and exact exclusions survive restart")
    let bytes = try Data(contentsOf: url)
    let json = String(decoding: bytes, as: UTF8.self)
    check(!json.contains("pid") && !json.contains("launchDate") && !json.contains("windowID"), "persistent settings contain no process or window lifetime identifiers")
    var bad = value; bad.height = 39
    do { try await store.save(bad); check(false, "out-of-range settings rejected") } catch { check(try Data(contentsOf: url) == bytes, "invalid settings preserve previous atomic file") }
    var failing = PinStorageIO(); failing.write = { _, _ in throw CocoaError(.fileWriteNoPermission) }
    do { try await SettingsStore(url: url, io: failing).save(WMacSettings()); check(false, "write failure surfaced") } catch { check(try Data(contentsOf: url) == bytes, "write failure preserves committed settings") }
    try Data("{\"version\":1,\"allDisplays\":false,\"height\":64,\"middleClick\":false}".utf8).write(to: url)
    let migrated = try await store.load()
    check(!migrated.allDisplays && migrated.height == 64 && !migrated.middleClick && migrated.opacity == 0.85, "version 1 migrates supplied fields with current defaults")
    check(try JSONDecoder().decode(SettingsStore.Document.self, from: Data(contentsOf: url)).version == 2, "migration commits current schema")
    for badBytes in [Data("broken".utf8), Data("{\"version\":999}".utf8)] {
        try badBytes.write(to: url)
        do { _ = try await store.load(); check(false, "bad settings rejected") } catch { check(try Data(contentsOf: url) == badBytes, "invalid/unsupported settings preserved for explicit recovery") }
    }
    _ = try await store.recover()
    let backups = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("settings-recovery-") }
    check(try backups.count == 1 && Data(contentsOf: backups[0]) == Data("{\"version\":999}".utf8), "explicit recovery retains exact original in unique backup")
    let controller = SettingsController(store: store)
    var publications = 0
    controller.changed = { publications += 1 }
    controller.load(); controller.edit { $0.height = 64 }; controller.edit { $0.middleClick = false }; controller.edit { $0.theme = .light }
    await controller.settled()
    let restarted = try await store.load()
    check(controller.value == restarted && restarted.height == 64 && !restarted.middleClick && restarted.theme == .light && publications == 4, "queued settings changes publish after save and propagate complete snapshots")
    let state = TaskbarCoordinator()
    let pin = ResolvedPin(pin: Pin(application: a, name: "A"), availability: .available, recoveryNote: nil)
    let one = Instance(id: InstanceID(pid: 17, launchDate: Date()), name: "A", url: a.url, bundleID: a.bundleID)
    let two = Instance(id: InstanceID(pid: 18, launchDate: Date()), name: "B", url: b.url, bundleID: b.bundleID)
    state.restore([pin]); state.apply([one, two], active: one.id); state.setExclusions([a])
    check(state.snapshot.buttons.count == 1 && state.snapshot.buttons[0].application == b && state.pins.count == 1 && state.snapshot.activeInstance == nil, "exclusions hide exact app pins/processes and preserve other paths and saved pins")
    state.setExclusions([])
    check(state.snapshot.buttons.count == 2 && state.snapshot.buttons[0].pinID == pin.pin.id, "restoring exclusion restores coordinator binding without duplicate processes")
    let screens = [DisplayLayout(id: 2, frame: CGRect(x: -1000, y: 0, width: 1000, height: 900)), DisplayLayout(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 900))]
    check(DisplayLayout.selected(screens, all: false, primary: 1).map(\.id) == [1] && DisplayLayout.selected(screens, all: true, primary: 1).count == 2, "primary selection follows identity independent of focus or array position")
    for height: Double in [40, 52, 64] {
        let layout = screens[0].panelFrame(height: height)
        let regions = PanelRegions(width: 1000, contentWidth: 4000, height: height)
        check(layout.height == height && layout.minX == -992 && regions.controls.minY >= 0 && regions.controls.maxY <= height && regions.controls.height >= 36 && regions.apps.height >= 36, "height \(height) preserves minimum targets and negative display geometry")
    }
}
