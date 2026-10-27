import Foundation

struct WMacSettings: Codable, Equatable, Sendable {
    enum Theme: String, Codable, CaseIterable, Sendable { case system, light, dark }
    var allDisplays = true
    var height: Double = 52
    /// Background opacity only; controls remain fully opaque.
    var opacity: Double = 0.85
    var theme: Theme = .system
    var middleClick = true
    var exclusions: [AppDefinition] = []
    var dockGuidanceSeen = false
    func validated() throws -> Self {
        guard height.isFinite, (40...64).contains(height), opacity.isFinite, (0.35...1).contains(opacity),
              exclusions.allSatisfy({ $0.url.isFileURL && !$0.bundleID.isEmpty }), Set(exclusions).count == exclusions.count else { throw SettingsError.invalid }
        return self
    }
}
enum SettingsError: LocalizedError {
    case invalid, unsupported(Int)
    var errorDescription: String? {
        let ru = Locale.preferredLanguages.first?.hasPrefix("ru") == true
        switch self {
        case .invalid: return ru ? "Некорректный файл настроек. Исходный файл сохранён." : "Invalid settings file. The original file is preserved."
        case .unsupported(let v): return ru ? "Версия настроек \(v) не поддерживается. Исходный файл сохранён." : "Settings version \(v) is unsupported. The original file is preserved."
        }
    }
}
actor SettingsStore {
    static var defaultURL: URL { PinStore.defaultURL.deletingLastPathComponent().appendingPathComponent("settings.json") }
    struct Document: Codable { let version: Int; let settings: WMacSettings }
    struct Legacy: Codable { let version: Int; let allDisplays: Bool; let height: Double; let middleClick: Bool }
    private let url: URL
    private let io: PinStorageIO
    init(url: URL = SettingsStore.defaultURL, io: PinStorageIO = PinStorageIO()) { self.url = url; self.io = io }
    func load() throws -> WMacSettings {
        guard io.exists(url) else { return WMacSettings() }
        let data = try io.read(url)
        struct Header: Decodable { let version: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).version
        let result: WMacSettings
        switch version {
        case 2: result = try JSONDecoder().decode(Document.self, from: data).settings
        case 1:
            let old = try JSONDecoder().decode(Legacy.self, from: data)
            var migrated = WMacSettings(); migrated.allDisplays = old.allDisplays; migrated.height = old.height; migrated.middleClick = old.middleClick
            result = migrated
        default: throw SettingsError.unsupported(version)
        }
        let valid = try result.validated()
        if version == 1 { try save(valid) }
        return valid
    }
    func save(_ value: WMacSettings) throws {
        let valid = try value.validated()
        try io.write(JSONEncoder().encode(Document(version: 2, settings: valid)), url)
    }
    /// Explicit recovery preserves the exact damaged/future file before replacement.
    func recover() throws -> WMacSettings {
        if io.exists(url) {
            let backup = url.deletingLastPathComponent().appendingPathComponent("settings-recovery-\(UUID().uuidString).json")
            try io.write(io.read(url), backup)
        }
        let value = WMacSettings(); try save(value); return value
    }
}
@MainActor final class SettingsController {
    let store: SettingsStore
    private(set) var value = WMacSettings()
    private(set) var ready = false
    private(set) var failure: String?
    private var tail: Task<Void, Never>?
    var changed: (() -> Void)?
    init(store: SettingsStore = SettingsStore()) { self.store = store }
    private func enqueue(_ action: @escaping @MainActor (SettingsController) async throws -> WMacSettings) {
        let previous = tail
        tail = Task { [self] in
            await previous?.value
            do { value = try await action(self); ready = true; failure = nil }
            catch { failure = error.localizedDescription }
            changed?()
        }
    }
    func load() { enqueue { owner in owner.ready = false; return try await owner.store.load() } }
    func edit(_ transform: @escaping @MainActor (inout WMacSettings) -> Void) {
        enqueue { owner in
            guard owner.ready else { throw SettingsError.invalid }
            var next = owner.value; transform(&next); try await owner.store.save(next); return next
        }
    }
    func recover() { enqueue { try await $0.store.recover() } }
    func settled() async { await tail?.value }
}
