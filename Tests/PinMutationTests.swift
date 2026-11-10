import AppKit

@MainActor func testPinMutations(_ check: (Bool, String) -> Void) async throws {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("WMacPins-\(UUID())")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    let path = folder.appendingPathComponent("pins.json")
    let a = AppDefinition(url: URL(fileURLWithPath: "/Applications/A.app"), bundleID: "test.a")
    let b = AppDefinition(url: URL(fileURLWithPath: "/Applications/B.app"), bundleID: "test.b")
    var io = PinStorageIO()
    io.bundleID = { _ in "test.a" }; io.bookmark = { _ in Data() }; io.resolve = { _ in throw CocoaError(.fileReadCorruptFile) }
    let store = PinStore(url: path, io: io)
    let state = TaskbarCoordinator()
    let operations = PinMutations(coordinator: state, store: store)
    operations.load(); operations.submit(.add(a, "A")); operations.submit(.add(b, "B"))
    await operations.wait()
    check(operations.loaded && state.pins.map { $0.pin.application } == [a, b], "rapid edits await initial load and earlier saves")
    let id = state.pins[1].pin.id
    operations.submit(.move(id, 0)); operations.submit(.move(id, 1)); operations.submit(.move(id, 0))
    await operations.wait()
    let restarted = try await store.load()
    check(restarted.pins.map { $0.pin.application } == [b, a] && state.pins.map(\.pin) == restarted.pins.map(\.pin), "rapid reorders commit latest FIFO order consistently with restart")
    let remembered = SavedWindowPlacement(displayUUID: UUID(), x: 123, y: 45, width: 800, height: 600)
    let positionCapture = ButtonCapture(state.snapshot.buttons[0])
    operations.submit(.placement(positionCapture, remembered)); await operations.wait()
    let rememberedDisk = try await store.load()
    check(state.pins[0].pin.savedWindowPlacement == remembered &&
          rememberedDisk.pins[0].pin.savedWindowPlacement == remembered,
          "remember commits the new geometry into the pin and the atomic v4 file")
    let replacement = SavedWindowPlacement(displayUUID: UUID(), x: -100, y: 20, width: 600, height: 420)
    operations.submit(.placement(positionCapture, replacement)); await operations.wait()
    check((try await store.load()).pins[0].pin.savedWindowPlacement == replacement,
          "remembering again replaces the previous monitor and geometry")
    operations.submit(.placement(positionCapture, nil)); await operations.wait()
    let forgottenDisk = try await store.load()
    check(state.pins[0].pin.savedWindowPlacement == nil &&
          forgottenDisk.pins[0].pin.savedWindowPlacement == nil,
          "forget clears saved position without changing pin identity or order")
    let captured = ButtonCapture(state.snapshot.buttons[0])
    state.relink(id, to: ResolvedPin(pin: Pin(application: a, name: "A"), availability: .available, recoveryNote: nil)) // duplicate rejected
    state.remove(id)
    operations.submit(.remove(captured)); operations.submit(.pin(captured)); await operations.wait()
    check(state.pins.count == 1, "stale pin and unpin captures cannot retarget a changed button")
    let before = try Data(contentsOf: path)
    operations.submit(.drop([URL(fileURLWithPath: "/System/Applications/TextEdit.app"), folder.appendingPathComponent("wrong.txt")]))
    await operations.wait()
    check(try operations.failure != nil && Data(contentsOf: path) == before && state.pins.count == 1, "mixed invalid Finder drop is all-or-nothing and preserves committed file")
    let missing = folder.appendingPathComponent("NotAnApplication.app")
    try fm.createDirectory(at: missing, withIntermediateDirectories: true)
    let malformed = await store.prepare(url: missing)
    let remote = await store.prepare(url: URL(string: "https://example.org/A.app")!)
    check(malformed == nil && remote == nil, "drop preparation rejects malformed bundles and non-file URLs")
    let real = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    operations.submit(.drop([real, real])); await operations.wait()
    check(state.pins.count == 2 && state.pins.last?.pin.application.url == real, "valid Finder bundle validation deduplicates repeated exact identities")
    let relinkID = state.pins[0].pin.id
    let relinkCapture = ButtonCapture(state.snapshot.buttons[0])
    operations.submit(.placement(relinkCapture, remembered)); await operations.wait()
    operations.submit(.relink(relinkCapture, real)); await operations.wait()
    check(operations.failure != nil && state.pins[0].pin.id == relinkID && state.pins[0].pin.application == a, "replacement rejects identity already pinned without altering original")
    operations.submit(.relink(relinkCapture, URL(fileURLWithPath: "/System/Applications/Calculator.app"))); await operations.wait()
    check(state.pins[0].pin.id == relinkID && state.pins[0].pin.application.bundleID == "com.apple.calculator" &&
          state.pins[0].pin.savedWindowPlacement == nil,
          "explicit Relink retains the pin UUID but intentionally resets remembered window geometry")
    var failureIO = io
    failureIO.write = { _, _ in throw CocoaError(.fileWriteNoPermission) }
    let failedState = TaskbarCoordinator()
    let failed = PinMutations(coordinator: failedState, store: PinStore(url: path, io: failureIO))
    failed.load(); await failed.wait()
    let saved = try Data(contentsOf: path)
    // Restore does not refresh the deliberately invalid bookmarks, so load succeeds.
    failed.submit(.add(b, "B")); await failed.wait()
    check(try failed.loaded && failed.failure != nil && failedState.pins.count == 2 && Data(contentsOf: path) == saved, "save failure keeps original UI and bytes and exposes retry state")
    let failureCapture = ButtonCapture(failedState.snapshot.buttons[0])
    failed.submit(.placement(failureCapture, remembered)); await failed.wait()
    check(try failed.failure != nil && failedState.pins[0].pin.savedWindowPlacement == nil &&
          Data(contentsOf: path) == saved,
          "failed atomic placement update cannot publish new geometry or alter saved bytes")
    try Data("invalid original".utf8).write(to: path)
    let invalidState = TaskbarCoordinator()
    let recovery = PinMutations(coordinator: invalidState, store: store)
    recovery.load(); recovery.submit(.add(a, "A")); await recovery.wait()
    check(try !recovery.loaded && invalidState.pins.isEmpty && Data(contentsOf: path) == Data("invalid original".utf8), "load failure gates queued edits without replacing corrupt original")
    try await store.save([])
    recovery.retry(); recovery.submit(.add(a, "A")); await recovery.wait()
    check(recovery.loaded && recovery.failure == nil && invalidState.pins.count == 1, "retry after explicit external file recovery resumes serialized mutations")
    try await testUnifiedTaskbarOrdering(check)
}

@MainActor func testUnifiedTaskbarOrdering(_ check: (Bool, String) -> Void) async throws {
    let a = AppDefinition(url: URL(fileURLWithPath: "/Applications/OrderingA.app"), bundleID: "test.order.a")
    let b = AppDefinition(url: URL(fileURLWithPath: "/Applications/OrderingB.app"), bundleID: "test.order.b")
    let c = AppDefinition(url: URL(fileURLWithPath: "/Applications/OrderingC.app"), bundleID: "test.order.c")
    func instance(_ id: Int32, _ time: Double, _ app: AppDefinition) -> Instance {
        Instance(id: InstanceID(pid: id, startDate: Date(timeIntervalSince1970: time)),
                 name: app.bundleID, url: app.url, bundleID: app.bundleID)
    }
    let ia = instance(110, 1, a), ib = instance(120, 2, b), ic = instance(130, 3, c)
    let state = TaskbarCoordinator()
    state.apply([ia, ib, ic], active: ia.id)
    check(state.snapshot.buttons.map(\.application) == [a, b, c], "unseen applications appear in discovery order")
    if let moved = state.layoutMovingButton(.instance(ib.id), toVisibleIndex: 0) {
        state.setLayout(moved)
    } else { check(false, "running application is draggable") }
    check(state.snapshot.buttons.map(\.application) == [b, a, c], "running applications can move between other running buttons")
    let saved = state.savedLayout
    let restarted = TaskbarCoordinator()
    restarted.apply([instance(211, 11, a), instance(221, 12, b), instance(231, 13, c)], active: nil)
    restarted.restore([], layout: saved)
    check(restarted.snapshot.buttons.map(\.application) == [b, a, c], "restart uses saved app positions, not PIDs")
    state.apply([ia, ic], active: nil)
    check(state.snapshot.buttons.map(\.application) == [a, c], "closed application leaves no blank button")
    let ibAgain = instance(220, 20, b)
    state.apply([ia, ic, ibAgain], active: nil)
    check(state.snapshot.buttons.map(\.application) == [b, a, c], "reopened app reuses its old layout slot")

    let pin = ResolvedPin(pin: Pin(application: b, name: "Ordering B"), availability: .available, recoveryNote: nil)
    let pinPreview = state.layoutAddingPin(pin.pin.id, replacing: .instance(ibAgain.id))
    check(pinPreview.compactMap(\.persistent).first == .pin(pin.pin.id), "pin conversion preserves on-screen location")
    check(state.add(pin, replacing: .instance(ibAgain.id)), "existing running app can be pinned")
    check(state.snapshot.buttons.first?.id == .pin(pin.pin.id), "pinning an app does not move its icon")
    let extraB = instance(230, 30, b)
    state.apply([ia, ic, ibAgain, extraB], active: nil)
    check(state.snapshot.buttons.filter { $0.application == b }.count == 2, "pin and extra application instance are separate buttons")
    check(Set(state.snapshot.buttons.compactMap { $0.instance?.id }).count == 4, "every live process is represented exactly once")
    state.remove(pin.pin.id)
    check(state.snapshot.buttons.first?.application == b && state.snapshot.buttons.first?.instance?.id == ibAgain.id,
          "unpinning an active app keeps its position and process")
    check(state.savedLayout.allSatisfy { if case .pin = $0 { return false }; return true },
          "removing the last pin does not leave orphan pin entries")

    let extraA = instance(140, 4, a)
    state.apply([ia, ic, ibAgain, extraB, extraA], active: nil)
    if let moved = state.layoutMovingButton(.instance(extraA.id), toVisibleIndex: 0) { state.setLayout(moved) }
    check(state.snapshot.buttons.first?.instance?.id == extraA.id, "individual same-app instances may be moved")
    check(state.savedLayout.filter { if case .application(let app, _) = $0 { return app == a }; return false }.count == 2,
          "each instance has a reusable stable app slot")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WMacUnifiedOrdering-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var io = PinStorageIO()
    io.bundleID = { _ in nil }
    let store = PinStore(url: dir.appendingPathComponent("pins.json"), io: io)
    try await store.save([], layout: state.savedLayout)
    let onDisk = try await store.load()
    check(onDisk.layout == state.savedLayout, "unified layout survives atomic storage round-trip")
    let encoded = try Data(contentsOf: dir.appendingPathComponent("pins.json"))
    let json = String(decoding: encoded, as: UTF8.self)
    check(!json.contains("\"pid\"") && !json.contains("startDate"), "no process lifetime identifiers are persisted")

    let unknown = Instance(id: InstanceID(pid: 310, startDate: Date(timeIntervalSince1970: 4)),
                           name: "Unnamed", url: nil, bundleID: "")
    state.apply([unknown, ia, ibAgain], active: nil)
    if let moved = state.layoutMovingButton(.instance(unknown.id), toVisibleIndex: 0) { state.setLayout(moved) }
    check(state.snapshot.buttons.first?.instance?.id == unknown.id, "unidentifiable processes remain draggable")
    check(!state.savedLayout.description.contains("310"), "unidentifiable process placement remains in memory only")

    // Exercise the serialized mutation path, not just the pure coordinator.
    let editedState = TaskbarCoordinator()
    let edits = PinMutations(coordinator: editedState, store: store)
    edits.load()
    await edits.wait()
    editedState.apply([ia, ibAgain, ic], active: nil)
    guard let icon = editedState.snapshot.buttons.first(where: { $0.instance?.id == ic.id }) else {
        check(false, "running process is available for persistent move"); return
    }
    edits.submit(.reorder(ButtonCapture(icon), 0))
    await edits.wait()
    check(editedState.snapshot.buttons.first?.instance?.id == ic.id && edits.failure == nil,
          "serialized runtime drag commits a visible reorder")
    let committed = try await store.load()
    check(committed.layout == editedState.savedLayout,
          "runtime drag commits the same order to persistent storage")

    // v2 persisted only pinned apps, so migration must preserve their order and IDs.
    struct LegacyV2: Codable { let version: Int; let pins: [Pin] }
    let oldPin = Pin(application: a, name: "Ordering A")
    let v2URL = dir.appendingPathComponent("pins-v2.json")
    try JSONEncoder().encode(LegacyV2(version: 2, pins: [oldPin])).write(to: v2URL)
    let v2Store = PinStore(url: v2URL, io: io)
    let migrated = try await v2Store.load()
    check(migrated.migrated && migrated.pins.first?.pin.id == oldPin.id && migrated.layout == [.pin(oldPin.id)],
          "v2 pins migrate to durable pin slots with preserved identity")
    let migratedAgain = try await v2Store.load()
    check(!migratedAgain.migrated, "v2 migration is idempotent")
    struct LegacyV3: Codable {
        let version: Int
        let pins: [Pin]
        let layout: [TaskbarLayoutSlot]
    }
    let v3URL = dir.appendingPathComponent("pins-v3.json")
    try JSONEncoder().encode(LegacyV3(version: 3, pins: [oldPin], layout: [.pin(oldPin.id)])).write(to: v3URL)
    let v3Store = PinStore(url: v3URL, io: io)
    let v3Load = try await v3Store.load()
    check(v3Load.migrated && v3Load.pins[0].pin.id == oldPin.id &&
          v3Load.pins[0].pin.savedWindowPlacement == nil &&
          v3Load.layout == [.pin(oldPin.id)],
          "v3 layout and pin identity migrate to v4 without an invented window position")
    let v3JSON = try Data(contentsOf: v3URL)
    let v3Again = try await v3Store.load()
    check(try JSONDecoder().decode(LegacyV3.self, from: v3JSON).version == 4 &&
          !v3Again.migrated,
          "v3 migration commits schema v4 atomically and is idempotent")
    let invalid = Pin(id: oldPin.id, application: a, name: "Bad",
                      savedWindowPlacement: SavedWindowPlacement(displayUUID: UUID(), x: 0, y: 0, width: 0, height: 120))
    do {
        try await v3Store.save([invalid])
        check(false, "invalid placement is rejected")
    } catch {
        check(try Data(contentsOf: v3URL) == v3JSON, "invalid placement leaves previously saved v4 bytes untouched")
    }
}
