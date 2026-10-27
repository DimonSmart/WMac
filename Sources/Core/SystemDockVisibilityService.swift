import Foundation
import CoreFoundation
import Darwin

// The only preferences modified by this feature are these three values in the
// current user's any-host com.apple.dock domain. Each value is stored as a
// binary property list so that nil, Bool, NSNumber and their types round-trip.
struct SystemDockEntry: Codable {
    let key: String
    let original: Data?
    let applied: Data
}

struct SystemDockTransaction: Codable {
    let version: Int
    let sessionID: UUID
    let ownerPID: Int32
    let ownerExecutable: String
    var phase: String
    let domain: String
    let user: String
    let host: String
    let entries: [SystemDockEntry]
}

protocol SystemDockPreferencesBackend {
    func read(_ key: String) throws -> Data?
    func write(_ key: String, value: Data?) throws
    func synchronize() throws
    func validate(_ key: String) throws
    func restartDock() throws
}

enum SystemDockFailure: LocalizedError {
    case busy, incompatible, watchdog, noPanels, preference(String), state(String)
    var errorDescription: String? {
        switch self {
        case .busy: "Another WMac session is managing the Dock."
        case .incompatible: "Dock recovery data is incompatible. Restore the Dock manually in System Settings."
        case .watchdog: "Dock watchdog could not be started or did not become ready."
        case .noPanels: "No WMac taskbar is ready."
        case .preference(let text): "Dock preferences: " + text
        case .state(let text): "Dock recovery: " + text
        }
    }
}

struct LiveSystemDockPreferences: SystemDockPreferencesBackend {
    private let domain: CFString = "com.apple.dock" as CFString
    func read(_ key: String) throws -> Data? {
        try Self.encode(CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
    }
    func validate(_ key: String) throws {
        if CFPreferencesAppValueIsForced(key as CFString, domain) {
            throw SystemDockFailure.preference("\(key) is managed by the system")
        }
        if CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) != nil ||
           CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost) != nil {
            throw SystemDockFailure.preference("\(key) has a host-specific override")
        }
    }
    func write(_ key: String, value: Data?) throws {
        let decoded = try value.map(Self.decode)
        CFPreferencesSetValue(key as CFString, decoded as CFPropertyList?, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    func synchronize() throws {
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw SystemDockFailure.preference("could not synchronize com.apple.dock")
        }
    }
    func restartDock() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() }
        catch { throw SystemDockFailure.preference("could not restart Dock: \(error.localizedDescription)") }
        guard process.terminationStatus == 0 else {
            throw SystemDockFailure.preference("Dock restart exited with status \(process.terminationStatus)")
        }
    }
    static func encode(_ value: Any?) throws -> Data? {
        guard let value else { return nil }
        return try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
    }
    static func decode(_ data: Data) throws -> Any {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let value = (plist as? [String: Any])?["value"] else { throw SystemDockFailure.incompatible }
        return value
    }
}

enum SystemDockRecovery {
    static var values: [(String, Any)] { [
        ("autohide", NSNumber(value: true)),
        ("autohide-delay", NSNumber(value: 1000.0)),
        ("autohide-time-modifier", NSNumber(value: 0.0))
    ] }
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WMac", isDirectory: true)
    }
    static var stateURL: URL { directory.appendingPathComponent("SystemDockVisibilityState.plist") }
    static var lockURL: URL { directory.appendingPathComponent("SystemDockVisibilityState.lock") }

    static func lock() throws -> Int32 {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SystemDockFailure.state("cannot open lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw SystemDockFailure.busy }
        return fd
    }
    static func unlock(_ fd: Int32) { _ = flock(fd, LOCK_UN); _ = close(fd) }

    static func load(_ url: URL) throws -> SystemDockTransaction? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let state = try PropertyListDecoder().decode(SystemDockTransaction.self, from: data)
        guard state.version == 1, state.domain == "com.apple.dock",
              state.user == "current", state.host == "any",
              Set(state.entries.map(\.key)) == Set(values.map(\.0)),
              state.entries.count == values.count, state.ownerPID > 0,
              !state.ownerExecutable.isEmpty,
              ["prepared", "applying", "active", "restoring"].contains(state.phase) else {
            throw SystemDockFailure.incompatible
        }
        for entry in state.entries {
            _ = try LiveSystemDockPreferences.decode(entry.applied)
            if let original = entry.original { _ = try LiveSystemDockPreferences.decode(original) }
        }
        return state
    }
    static func save(_ state: SystemDockTransaction, to url: URL) throws {
        try PropertyListEncoder().encode(state).write(to: url, options: .atomic)
    }
    // Compare-and-restore prevents overwriting a value changed by the user.
    // The same routine is used by the app and by the crash watchdog.
    @discardableResult static func restore(_ url: URL, backend: any SystemDockPreferencesBackend) throws -> [String] {
        guard var state = try load(url) else { return [] }
        // A prepared transaction has not written any preferences yet.
        if state.phase == "prepared" {
            try FileManager.default.removeItem(at: url)
            return []
        }
        state.phase = "restoring"
        try save(state, to: url)
        var conflicts: [String] = []
        var changed = false
        for entry in state.entries {
            let current = try backend.read(entry.key)
            if current == entry.applied {
                if current != entry.original {
                    try backend.write(entry.key, value: entry.original)
                    changed = true
                }
            } else if current != entry.original {
                conflicts.append(entry.key)
            }
        }
        if changed {
            try backend.synchronize()
            for entry in state.entries {
                let actual = try backend.read(entry.key)
                if !conflicts.contains(entry.key) && actual != entry.original {
                    throw SystemDockFailure.preference("restore verification failed for \(entry.key)")
                }
            }
            try backend.restartDock()
        }
        try FileManager.default.removeItem(at: url)
        return conflicts
    }
}

@MainActor final class SystemDockVisibilityService {
    enum Status { case inactive, active, failed(String) }
    private(set) var status: Status = .inactive
    var changed: (() -> Void)?
    private let backend: any SystemDockPreferencesBackend
    private let stateURL: URL
    private let lockURL: URL
    private var lockFD: Int32?
    private var sessionID: UUID?
    private var watchdog: Process?

    init(backend: any SystemDockPreferencesBackend = LiveSystemDockPreferences(),
         stateURL: URL = SystemDockRecovery.stateURL,
         lockURL: URL = SystemDockRecovery.lockURL) {
        self.backend = backend
        self.stateURL = stateURL
        self.lockURL = lockURL
    }
    var active: Bool { if case .active = status { return true }; return false }
    var needsRecovery: Bool { active || FileManager.default.fileExists(atPath: stateURL.path) }
    var message: String {
        switch status {
        case .inactive: return ""
        case .active: return "System Dock hidden"
        case .failed(let reason): return "Could not hide Dock: " + reason
        }
    }
    private func releaseLock() {
        if let lockFD { SystemDockRecovery.unlock(lockFD); self.lockFD = nil }
    }
    private func obtainLock() throws {
        guard lockFD == nil else { return }
        // Test instances may supply a separate lock path; the real app uses the
        // stable WMac lock, across all processes and all launches.
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SystemDockFailure.state("cannot open lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw SystemDockFailure.busy }
        lockFD = fd
    }
    func recoverAtLaunch() {
        do {
            try obtainLock()
            _ = try SystemDockRecovery.restore(stateURL, backend: backend)
            releaseLock()
            status = .inactive
        } catch { releaseLock(); status = .failed(error.localizedDescription) }
        changed?()
    }
    func enable(panelsReady: Bool) {
        if active { return }
        guard panelsReady else { status = .failed(SystemDockFailure.noPanels.localizedDescription); changed?(); return }
        do {
            try obtainLock()
            guard try SystemDockRecovery.load(stateURL) == nil else {
                throw SystemDockFailure.state("pending recovery must complete first")
            }
            let entries = try SystemDockRecovery.values.map { key, value -> SystemDockEntry in
                try backend.validate(key)
                return SystemDockEntry(key: key, original: try backend.read(key),
                                       applied: try LiveSystemDockPreferences.encode(value)!)
            }
            let id = UUID()
            let state = SystemDockTransaction(version: 1, sessionID: id, ownerPID: getpid(),
                ownerExecutable: CommandLine.arguments[0], phase: "prepared",
                domain: "com.apple.dock", user: "current", host: "any", entries: entries)
            try SystemDockRecovery.save(state, to: stateURL)
            sessionID = id
            try startWatchdog(id)
            var applying = state
            applying.phase = "applying"
            try SystemDockRecovery.save(applying, to: stateURL)
            let modifications = entries.filter { $0.original != $0.applied }
            if !modifications.isEmpty {
                for entry in modifications { try backend.write(entry.key, value: entry.applied) }
                try backend.synchronize()
                for entry in entries {
                    if try backend.read(entry.key) != entry.applied {
                        throw SystemDockFailure.preference("verification failed for \(entry.key)")
                    }
                }
                try backend.restartDock()
            }
            applying.phase = "active"
            try SystemDockRecovery.save(applying, to: stateURL)
            status = .active
        } catch {
            let reason = error.localizedDescription
            do { _ = try SystemDockRecovery.restore(stateURL, backend: backend) }
            catch { status = .failed(reason + "; recovery failed: " + error.localizedDescription); changed?(); return }
            if let watchdog, watchdog.isRunning { watchdog.terminate() }
            watchdog = nil
            sessionID = nil
            releaseLock()
            status = .failed(reason)
        }
        changed?()
    }
    func restore() {
        do {
            let hadState = needsRecovery
            try obtainLock()
            let conflicts = try SystemDockRecovery.restore(stateURL, backend: backend)
            if let watchdog, watchdog.isRunning { watchdog.terminate() }
            watchdog = nil
            sessionID = nil
            releaseLock()
            status = conflicts.isEmpty ? .inactive : .failed("External Dock preference changes retained: " + conflicts.joined(separator: ", "))
            if !hadState { status = .inactive }
        } catch { status = .failed(error.localizedDescription) }
        changed?()
    }
    private func startWatchdog(_ id: UUID) throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/WMacDockWatchdog")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw SystemDockFailure.watchdog }
        let process = Process()
        process.executableURL = helper
        process.arguments = [String(getpid()), id.uuidString, stateURL.path, lockURL.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        var descriptor = pollfd(fd: stdout.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, 3000)
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = result > 0 ? read(descriptor.fd, &buffer, buffer.count) : -1
        guard count > 0 && String(decoding: buffer.prefix(count), as: UTF8.self).contains("READY") else {
            if process.isRunning { process.terminate() }
            throw SystemDockFailure.watchdog
        }
        watchdog = process
        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                guard let self, self.watchdog === terminated, self.active else { return }
                self.restore()
            }
        }
    }
}
