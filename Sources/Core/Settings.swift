import Foundation

enum HoverPreviewMode: String, Codable, CaseIterable, Sendable {
    case automatic, always, disabled

    // Keep decoding the previous global Always value while omitting this now
    // redundant choice from settings. Per-app Always overrides remain available.
    static var selectableCases: [Self] { [.automatic, .disabled] }
}
enum AppHoverPreviewMode: String, Codable, CaseIterable, Sendable { case always, disabled }
struct AppPreviewPreference: Codable, Equatable, Sendable {
    var application: AppDefinition
    var mode: AppHoverPreviewMode
}
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
    var hideSystemDock = false
    var hoverPreviews: HoverPreviewMode = .automatic
    var showWindowThumbnails = true
    var appPreviewPreferences: [AppPreviewPreference] = []
    var windowArrangementShortcuts = false

    func hoverMode(for app: AppDefinition?) -> HoverPreviewMode {
        guard let app, let mode = appPreviewPreferences.first(where: { $0.application == app })?.mode else { return hoverPreviews }
        return mode == .always ? .always : .disabled
    }
    func shouldPreview(_ windowCount: Int, app: AppDefinition?) -> Bool {
        switch hoverMode(for: app) {
        case .automatic: return windowCount >= 1
        case .always: return windowCount >= 1
        case .disabled: return false
        }
    }
    mutating func setHoverOverride(_ mode: AppHoverPreviewMode?, for app: AppDefinition) {
        appPreviewPreferences.removeAll { $0.application == app }
        if let mode { appPreviewPreferences.append(AppPreviewPreference(application: app, mode: mode)) }
    }

    init() {}
    enum CodingKeys: String, CodingKey {
        case allDisplays, height, opacity, theme, middleClick, exclusions, dockGuidanceSeen, hideSystemDock, hoverPreviews, showWindowThumbnails, appPreviewPreferences, windowArrangementShortcuts
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allDisplays = try c.decodeIfPresent(Bool.self, forKey: .allDisplays) ?? allDisplays
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? height
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? theme
        middleClick = try c.decodeIfPresent(Bool.self, forKey: .middleClick) ?? middleClick
        exclusions = try c.decodeIfPresent([AppDefinition].self, forKey: .exclusions) ?? exclusions
        dockGuidanceSeen = try c.decodeIfPresent(Bool.self, forKey: .dockGuidanceSeen) ?? dockGuidanceSeen
        hideSystemDock = try c.decodeIfPresent(Bool.self, forKey: .hideSystemDock) ?? false
        hoverPreviews = try c.decodeIfPresent(HoverPreviewMode.self, forKey: .hoverPreviews) ?? .automatic
        showWindowThumbnails = try c.decodeIfPresent(Bool.self, forKey: .showWindowThumbnails) ?? true
        appPreviewPreferences = try c.decodeIfPresent([AppPreviewPreference].self, forKey: .appPreviewPreferences) ?? []
        windowArrangementShortcuts = try c.decodeIfPresent(Bool.self, forKey: .windowArrangementShortcuts) ?? false
    }
    func validated() throws -> Self {
        guard height.isFinite, (40...64).contains(height), opacity.isFinite, (0.35...1).contains(opacity),
              exclusions.allSatisfy({ $0.url.isFileURL && !$0.bundleID.isEmpty }), Set(exclusions).count == exclusions.count,
              appPreviewPreferences.allSatisfy({ $0.application.url.isFileURL && !$0.application.bundleID.isEmpty }),
              Set(appPreviewPreferences.map(\.application)).count == appPreviewPreferences.count else { throw SettingsError.invalid }
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
        case 2, 3, 4: result = try JSONDecoder().decode(Document.self, from: data).settings
        case 1:
            let old = try JSONDecoder().decode(Legacy.self, from: data)
            var migrated = WMacSettings(); migrated.allDisplays = old.allDisplays; migrated.height = old.height; migrated.middleClick = old.middleClick
            result = migrated
        default: throw SettingsError.unsupported(version)
        }
        let valid = try result.validated()
        if version != 4 { try save(valid) }
        return valid
    }
    func save(_ value: WMacSettings) throws {
        let valid = try value.validated()
        try io.write(JSONEncoder().encode(Document(version: 4, settings: valid)), url)
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
