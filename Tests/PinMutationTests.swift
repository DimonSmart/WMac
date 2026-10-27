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
    operations.submit(.relink(relinkCapture, real)); await operations.wait()
    check(operations.failure != nil && state.pins[0].pin.id == relinkID && state.pins[0].pin.application == a, "replacement rejects identity already pinned without altering original")
    operations.submit(.relink(relinkCapture, URL(fileURLWithPath: "/System/Applications/Calculator.app"))); await operations.wait()
    check(state.pins[0].pin.id == relinkID && state.pins[0].pin.application.bundleID == "com.apple.calculator", "replacement picker mutation preserves UUID and installs validated new bundle identity")
    var failureIO = io
    failureIO.write = { _, _ in throw CocoaError(.fileWriteNoPermission) }
    let failedState = TaskbarCoordinator()
    let failed = PinMutations(coordinator: failedState, store: PinStore(url: path, io: failureIO))
    failed.load(); await failed.wait()
    let saved = try Data(contentsOf: path)
    // Restore does not refresh the deliberately invalid bookmarks, so load succeeds.
    failed.submit(.add(b, "B")); await failed.wait()
    check(try failed.loaded && failed.failure != nil && failedState.pins.count == 2 && Data(contentsOf: path) == saved, "save failure keeps original UI and bytes and exposes retry state")
    try Data("invalid original".utf8).write(to: path)
    let invalidState = TaskbarCoordinator()
    let recovery = PinMutations(coordinator: invalidState, store: store)
    recovery.load(); recovery.submit(.add(a, "A")); await recovery.wait()
    check(try !recovery.loaded && invalidState.pins.isEmpty && Data(contentsOf: path) == Data("invalid original".utf8), "load failure gates queued edits without replacing corrupt original")
    try await store.save([])
    recovery.retry(); recovery.submit(.add(a, "A")); await recovery.wait()
    check(recovery.loaded && recovery.failure == nil && invalidState.pins.count == 1, "retry after explicit external file recovery resumes serialized mutations")
}
