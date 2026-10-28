import Foundation

struct BookmarkResolution: Sendable {
    let url: URL
    let stale: Bool
}
struct PinStorageIO: Sendable {
    var read: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    var write: @Sendable (Data, URL) throws -> Void = { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    var exists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    var bundleID: @Sendable (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }
    var bookmark: @Sendable (URL) throws -> Data = { try $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
    var resolve: @Sendable (Data) throws -> BookmarkResolution = { data in
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        return BookmarkResolution(url: url, stale: stale)
    }
}
enum PinStoreError: LocalizedError {
    case unsupportedVersion(Int), invalidState
    var errorDescription: String? {
        let ru = Locale.preferredLanguages.first?.hasPrefix("ru") == true
        switch self {
        case .unsupportedVersion(let version): return ru ? "Версия файла закреплений \(version) не поддерживается. Восстановите совместимую резервную копию." : "Pin file version \(version) is unsupported. Restore a compatible backup."
        case .invalidState: return ru ? "Некорректное закрепление или приложение. Выберите доступное GUI-приложение .app, которое ещё не закреплено." : "Invalid pin or application. Choose an available GUI .app that is not already pinned."
        }
    }
}
struct PinLoad: Sendable { let pins: [ResolvedPin]; let migrated: Bool }

/// Synchronous filesystem calls execute exclusively on this actor, never the UI actor.
actor PinStore {
    static let currentVersion = 2
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WMac/pins.json")
    }
    private let url: URL
    private let io: PinStorageIO
    private struct Header: Codable { let version: Int }
    private struct Document: Codable { let version: Int; let pins: [Pin] }
    // Version 1 used a path string and had no stable pin UUID or bookmark.
    private struct Legacy: Codable {
        struct Entry: Codable { let path: String; let bundleID: String; let name: String }
        let version: Int; let pins: [Entry]
    }
    init(url: URL = PinStore.defaultURL, io: PinStorageIO = PinStorageIO()) { self.url = url; self.io = io }
    func prepare(url: URL) -> ResolvedPin? {
        var scanner = ApplicationCatalogScanner()
        scanner.roots = []
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              let application = scanner.scan(supplementalURLs: [url]).first,
              !application.isMenuBarOnly else { return nil }
        return prepare(application: application.definition, name: application.name)
    }
    func prepare(application: AppDefinition, name: String, id: UUID = UUID()) -> ResolvedPin {
        recover(Pin(id: id, application: application, name: name, bookmark: try? io.bookmark(application.url)))
    }
    func load() throws -> PinLoad {
        guard io.exists(url) else { return PinLoad(pins: [], migrated: false) }
        let data = try io.read(url)
        let version = try JSONDecoder().decode(Header.self, from: data).version
        let pins: [Pin]
        switch version {
        case Self.currentVersion: pins = try JSONDecoder().decode(Document.self, from: data).pins
        case 1:
            pins = try JSONDecoder().decode(Legacy.self, from: data).pins.map {
                Pin(application: AppDefinition(url: URL(fileURLWithPath: $0.path), bundleID: $0.bundleID), name: $0.name)
            }
        default: throw PinStoreError.unsupportedVersion(version)
        }
        var ids = Set<UUID>(); var definitions = Set<AppDefinition>()
        let recovered = try pins.map { pin -> ResolvedPin in
            guard pin.application.url.isFileURL, !pin.application.bundleID.isEmpty else { throw PinStoreError.invalidState }
            let value = recover(pin)
            guard ids.insert(value.pin.id).inserted, definitions.insert(value.pin.application).inserted else { throw PinStoreError.invalidState }
            return value
        }
        // Migration and refreshed bookmarks are committed atomically; failure preserves the previous file.
        if version != Self.currentVersion || recovered.map(\.pin) != pins { try save(recovered.map(\.pin)) }
        return PinLoad(pins: recovered, migrated: version != Self.currentVersion)
    }
    func save(_ pins: [Pin]) throws {
        let data = try JSONEncoder().encode(Document(version: Self.currentVersion, pins: pins))
        try io.write(data, url)
    }
    private func recover(_ original: Pin) -> ResolvedPin {
        let definition = AppDefinition(url: original.application.url, bundleID: original.application.bundleID)
        var target = definition
        var bookmark = original.bookmark
        var note: String?
        if let data = bookmark {
            do {
                let resolved = try io.resolve(data)
                let candidate = AppDefinition(url: resolved.url, bundleID: definition.bundleID)
                if io.bundleID(candidate.url) == definition.bundleID {
                    target = candidate
                    if resolved.stale || candidate != definition {
                        bookmark = try? io.bookmark(candidate.url)
                        note = "Recovered application bookmark"
                    }
                } else { note = "Bookmark target unavailable or identity changed; relink application" }
            } catch { note = "Invalid bookmark; relink application if original path is unavailable" }
        }
        let available = io.bundleID(target.url) == target.bundleID
        return ResolvedPin(pin: Pin(id: original.id, application: target, name: original.name, bookmark: bookmark),
                           availability: available ? .available : .missing, recoveryNote: note)
    }
}


/// All asynchronous loads and edits form one FIFO. Nothing publishes until its atomic save succeeds.
@MainActor final class PinMutations {
    enum Edit: Sendable {
        case add(AppDefinition, String), pin(ButtonCapture), drop([URL]), remove(ButtonCapture), move(UUID, Int), relink(ButtonCapture, URL)
    }
    let coordinator: TaskbarCoordinator
    let store: PinStore
    private var tail: Task<Void, Never>?
    private(set) var loaded = false
    private(set) var failure: String?
    private var failedEdit: Edit?
    var changed: (() -> Void)?
    var validate: ((ButtonCapture) -> Bool)?
    init(coordinator: TaskbarCoordinator, store: PinStore) { self.coordinator = coordinator; self.store = store }
    func load() {
        enqueue { owner in
            do {
                let result = try await owner.store.load()
                owner.coordinator.restore(result.pins); owner.loaded = true; owner.failure = nil
            } catch { owner.loaded = false; owner.failure = error.localizedDescription }
            owner.changed?()
        }
    }
    func submit(_ edit: Edit) {
        enqueue { owner in
            guard owner.loaded else { owner.changed?(); return }
            do {
                switch edit {
                case .add(let definition, let name):
                    guard !owner.coordinator.pins.contains(where: { $0.pin.application == definition }) else { return }
                    let pin = await owner.store.prepare(application: definition, name: name)
                    try await owner.store.save(owner.coordinator.pins.map(\.pin) + [pin.pin])
                    owner.coordinator.add(pin)
                case .pin(let capture):
                    guard owner.valid(capture), let definition = capture.application,
                          !owner.coordinator.pins.contains(where: { $0.pin.application == definition }) else { return }
                    let name = owner.coordinator.snapshot.buttons.first { $0.id == capture.button }?.name ?? definition.url.deletingPathExtension().lastPathComponent
                    let pin = await owner.store.prepare(application: definition, name: name)
                    guard owner.valid(capture) else { return }
                    try await owner.store.save(owner.coordinator.pins.map(\.pin) + [pin.pin])
                    owner.coordinator.add(pin)
                case .drop(let urls):
                    var additions: [ResolvedPin] = []
                    for url in urls {
                        guard let pin = await owner.store.prepare(url: url) else { throw PinStoreError.invalidState }
                        if !owner.coordinator.pins.contains(where: { $0.pin.application == pin.pin.application }),
                           !additions.contains(where: { $0.pin.application == pin.pin.application }) { additions.append(pin) }
                    }
                    guard !additions.isEmpty else { return }
                    try await owner.store.save(owner.coordinator.pins.map(\.pin) + additions.map(\.pin))
                    for pin in additions { owner.coordinator.add(pin) }
                case .remove(let capture):
                    guard owner.valid(capture), case .pin(let id) = capture.button else { return }
                    try await owner.store.save(owner.coordinator.pins.filter { $0.pin.id != id }.map(\.pin))
                    owner.coordinator.remove(id)
                case .move(let id, let index):
                    guard let old = owner.coordinator.pins.firstIndex(where: { $0.pin.id == id }) else { return }
                    var order = owner.coordinator.pins.map(\.pin)
                    let pin = order.remove(at: old); order.insert(pin, at: min(max(0, index), order.count))
                    try await owner.store.save(order); owner.coordinator.move(id, to: index)
                case .relink(let capture, let url):
                    guard owner.valid(capture), case .pin(let id) = capture.button,
                          let index = owner.coordinator.pins.firstIndex(where: { $0.pin.id == id }) else { return }
                    guard let replacement = await owner.store.prepare(url: url),
                          !owner.coordinator.pins.contains(where: { $0.pin.id != id && $0.pin.application == replacement.pin.application }) else { throw PinStoreError.invalidState }
                    // Picker and preparation can suspend; preserve the original captured instance.
                    guard owner.valid(capture) else { return }
                    var order = owner.coordinator.pins.map(\.pin)
                    order[index] = Pin(id: id, application: replacement.pin.application, name: replacement.pin.name, bookmark: replacement.pin.bookmark)
                    try await owner.store.save(order); owner.coordinator.relink(id, to: replacement)
                }
                owner.failure = nil; owner.failedEdit = nil
            } catch { owner.failure = error.localizedDescription; owner.failedEdit = edit }
            owner.changed?()
        }
    }
    func retry() { if !loaded { load() } else if let failedEdit { submit(failedEdit) } }
    func wait() async { await tail?.value }
    private func valid(_ capture: ButtonCapture) -> Bool { capture.matches(coordinator.snapshot) && (validate?(capture) ?? true) }
    private func enqueue(_ operation: @escaping @MainActor (PinMutations) async -> Void) {
        let previous = tail
        tail = Task { await previous?.value; await operation(self) }
    }
}
