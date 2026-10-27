import Foundation
import Darwin

private final class FakeDockBackend: SystemDockPreferencesBackend {
    var values: [String: Data] = [:]
    var restarts = 0
    var writes = 0
    var failOnWrite: String?
    func read(_ key: String) throws -> Data? { values[key] }
    func write(_ key: String, value: Data?) throws {
        if key == failOnWrite { throw SystemDockFailure.preference("injected write failure") }
        values[key] = value
        writes += 1
    }
    func synchronize() throws {}
    func validate(_ key: String) throws {}
    func restartDock() throws { restarts += 1 }
}

@MainActor func testSystemDockRecovery(_ check: (Bool, String) -> Void) throws {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("WMacDockTests-\(UUID())")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    let stateURL = folder.appendingPathComponent("state.plist")
    let lockURL = folder.appendingPathComponent("state.lock")
    let backend = FakeDockBackend()
    let records = try SystemDockRecovery.values.enumerated().map { index, pair -> SystemDockEntry in
        let original = index == 0 ? try LiveSystemDockPreferences.encode(NSNumber(value: false)) : nil
        let applied = try LiveSystemDockPreferences.encode(pair.1)!
        backend.values[pair.0] = applied
        return SystemDockEntry(key: pair.0, original: original, applied: applied)
    }
    func snapshot() -> SystemDockTransaction {
        SystemDockTransaction(version: 1, sessionID: UUID(), ownerPID: 1,
            ownerExecutable: "test", phase: "active", domain: "com.apple.dock",
            user: "current", host: "any", entries: records)
    }
    try SystemDockRecovery.save(snapshot(), to: stateURL)
    let restored = try SystemDockRecovery.restore(stateURL, backend: backend)
    check(restored.isEmpty && backend.values["autohide"] == records[0].original &&
        backend.values["autohide-delay"] == nil && backend.values["autohide-time-modifier"] == nil,
        "restore preserves bool type and deletes originally absent preferences")
    check(backend.restarts == 1 && !fm.fileExists(atPath: stateURL.path),
          "restored transaction restarts Dock once and removes snapshot")
    _ = try SystemDockRecovery.restore(stateURL, backend: backend)
    check(backend.restarts == 1, "repeated restoration is idempotent")

    for entry in records { backend.values[entry.key] = entry.applied }
    let external = try LiveSystemDockPreferences.encode(NSNumber(value: 42.0))!
    backend.values["autohide-delay"] = external
    try SystemDockRecovery.save(snapshot(), to: stateURL)
    let conflicts = try SystemDockRecovery.restore(stateURL, backend: backend)
    check(conflicts == ["autohide-delay"] && backend.values["autohide-delay"] == external,
          "external preference changes win over the original snapshot")

    try Data("corrupt".utf8).write(to: stateURL)
    let count = backend.writes
    do { _ = try SystemDockRecovery.restore(stateURL, backend: backend); check(false, "corrupt state rejected") }
    catch { check(backend.writes == count && fm.fileExists(atPath: stateURL.path),
                  "corrupt state neither changes Dock nor removes recovery evidence") }
    try fm.removeItem(at: stateURL)

    let controller = SystemDockVisibilityService(backend: backend, stateURL: stateURL, lockURL: lockURL)
    controller.enable(panelsReady: false)
    check(backend.writes == count, "hiding without WMac panels does not modify preferences")
    controller.enable(panelsReady: true)
    check(!controller.active && backend.writes == count &&
          !fm.fileExists(atPath: stateURL.path),
          "missing helper refuses to hide and rolls back prepared state")
    let lockFD = open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
    guard lockFD >= 0 else { throw SystemDockFailure.state("test lock unavailable") }
    _ = flock(lockFD, LOCK_EX | LOCK_NB)
    let contender = SystemDockVisibilityService(backend: backend, stateURL: stateURL, lockURL: lockURL)
    contender.enable(panelsReady: true)
    check(!contender.active && backend.writes == count,
          "concurrent instance cannot modify preferences while lock is held")
    SystemDockRecovery.unlock(lockFD)
}
