import Foundation

@MainActor func testSettings(_ check: (Bool, String) -> Void) async throws {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("WMacSettings-\(UUID())")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    let url = folder.appendingPathComponent("settings.json")
    let store = SettingsStore(url: url)
    check(try await store.load() == WMacSettings(), "missing settings use sensible defaults")
    let defaultPreview = WMacSettings()
    check(!defaultPreview.shouldPreview(0, app: nil) && defaultPreview.shouldPreview(1, app: nil) &&
          defaultPreview.shouldPreview(2, app: nil) && defaultPreview.showWindowThumbnails,
          "automatic previews include one or more AX windows and thumbnails are opt-in by OS permission")
    var neverPreview = defaultPreview
    neverPreview.hoverPreviews = .disabled
    check(!neverPreview.shouldPreview(4, app: nil), "disabled hover never opens automatically")

    var value = WMacSettings(); value.theme = .dark; value.height = 40; value.opacity = 0.35; value.middleClick = false
    let a = AppDefinition(url: URL(fileURLWithPath: "/Applications/A.app"), bundleID: "a")
    let b = AppDefinition(url: URL(fileURLWithPath: "/Applications/B.app"), bundleID: "a")
    value.dockGuidanceSeen = true; value.hideSystemDock = true; value.reserveTaskbarSpace = true
    value.hoverPreviews = .always; value.showWindowThumbnails = false; value.setHoverOverride(.disabled, for: b)
    try await store.save(value)
    check(try await SettingsStore(url: url).load() == value, "settings survive restart")
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
    check(try JSONDecoder().decode(SettingsStore.Document.self, from: Data(contentsOf: url)).version == 5, "migration commits current schema v5")
    try Data("{\"version\":2,\"settings\":{\"allDisplays\":true,\"height\":52,\"opacity\":0.85,\"theme\":\"system\",\"middleClick\":true,\"exclusions\":[],\"dockGuidanceSeen\":true}}".utf8).write(to: url)
    let v2 = try await store.load()
    check(!v2.hideSystemDock && !v2.reserveTaskbarSpace, "v2 migrates with opt-in window management disabled")
    check(try JSONDecoder().decode(SettingsStore.Document.self, from: Data(contentsOf: url)).version == 5, "v2 migration commits schema v5")
    try Data(#"{"version":3,"settings":{"allDisplays":false,"height":52,"opacity":0.85}}"#.utf8).write(to: url)
    let v3 = try await store.load()
    check(!v3.allDisplays && v3.hoverPreviews == .automatic && v3.showWindowThumbnails && v3.appPreviewPreferences.isEmpty, "v3 migration defaults preserve existing settings")
    check(try JSONDecoder().decode(SettingsStore.Document.self, from: Data(contentsOf: url)).version == 5, "v3 migration commits schema v5")
    check(!value.shouldPreview(4, app: b) && value.shouldPreview(1, app: a), "per-application override and legacy always setting use definition identity")
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
    let one = Instance(id: InstanceID(pid: 17, startDate: Date()), name: "A", url: a.url, bundleID: a.bundleID)
    let two = Instance(id: InstanceID(pid: 18, startDate: Date()), name: "B", url: b.url, bundleID: b.bundleID)
    state.restore([pin]); state.apply([one, two], active: one.id)
    check(state.snapshot.buttons.count == 2 && state.snapshot.buttons[0].pinID == pin.pin.id, "all supported applications remain represented alongside their pins")
    let screens = [DisplayLayout(id: 2, frame: CGRect(x: -1000, y: 0, width: 1000, height: 900)), DisplayLayout(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 900))]
    check(DisplayLayout.selected(screens, all: false, primary: 1).map(\.id) == [1] && DisplayLayout.selected(screens, all: true, primary: 1).count == 2, "primary selection follows identity independent of focus or array position")
    for height: Double in [40, 52, 64] {
        let layout = screens[0].panelFrame(height: height)
        let regions = PanelRegions(width: 1000, contentWidth: 4000, height: height)
        check(layout.height == height && layout.minX == -992 && regions.controls.minY >= 0 && regions.controls.maxY <= height && regions.controls.height >= 36 && regions.apps.height >= 36, "height \(height) preserves minimum targets and negative display geometry")
    }

    let visible = CGRect(x: 0, y: 24, width: 1440, height: 876)
    let full = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let reserved = CGRect(x: 0, y: 24, width: 1440, height: 812)
    check(WindowReservationGeometry.adjustedFrame(visible, visible: visible, full: full, available: reserved)
          == reserved, "zoomed window shrinks to virtual work area")
    let tile = CGRect(x: 0, y: 462, width: 720, height: 438)
    check(WindowReservationGeometry.adjustedFrame(tile, visible: visible, full: full, available: reserved)
          == CGRect(x: 0, y: 462, width: 720, height: 374), "system bottom-half tiling keeps its horizontal geometry")
    check(WindowReservationGeometry.adjustedFrame(CGRect(x: 70, y: 70, width: 1000, height: 830),
          visible: visible, full: full, available: reserved) == nil, "manually placed windows are untouched")
    check(WindowReservationGeometry.adjustedFrame(full, visible: visible, full: full, available: reserved) == nil,
          "native fullscreen geometry is untouched")
    check(WindowReservationGeometry.adjustedFrame(reserved, visible: visible, full: full, available: reserved) == nil,
          "already corrected windows do not generate resize loops")
    let external = WindowReservationDisplay(id: 2, frame: CGRect(x: -1200, y: 100, width: 1200, height: 800),
        visible: CGRect(x: -1200, y: 124, width: 1200, height: 776),
        available: CGRect(x: -1200, y: 124, width: 1200, height: 712),
        appKitAvailable: CGRect(x: -1200, y: 64, width: 1200, height: 712))
    let primary = WindowReservationDisplay(id: 1, frame: full, visible: visible,
        available: reserved, appKitAvailable: reserved)
    check(WindowReservationGeometry.bestDisplay(for: CGRect(x: -1100, y: 140, width: 1000, height: 700),
          in: [primary, external])?.id == 2, "reservation selects the intersected external display")
}
