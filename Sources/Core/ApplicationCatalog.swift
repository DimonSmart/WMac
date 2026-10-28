import AppKit

/// Selection retains this definition verbatim for launch and pin actions.
struct CatalogApplication: Identifiable, Sendable {
    let definition: AppDefinition
    let name: String
    let iconData: Data?
    let isMenuBarOnly: Bool
    var id: AppDefinition { definition }

    @MainActor var icon: NSImage {
        iconData.flatMap(NSImage.init(data:)) ?? NSImage(named: NSImage.applicationIconName) ?? NSImage(size: NSSize(width: 32, height: 32))
    }

    func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { name.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ru_RU")) != nil }
    }
}

struct ApplicationCatalogScanner: Sendable {
    static var standardRoots: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         URL(fileURLWithPath: "/System/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }
    var roots: [URL] = Self.standardRoots
    var preferredLanguages: [String] = Locale.preferredLanguages
    var excludedBundleIDs: Set<String> = ["app.wmac.WMac"]

    /// Synchronous filesystem work is called only from the catalog's detached task.
    func scan(supplementalURLs: [URL] = []) -> [CatalogApplication] {
        let fm = FileManager.default
        var visited = Set<URL>()
        var applications: [AppDefinition: CatalogApplication] = [:]
        func inspect(_ input: URL, depth: Int) {
            let url = input.resolvingSymlinksInPath().standardizedFileURL
            guard depth <= 5, visited.insert(url).inserted,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey]),
                  values.isDirectory == true, values.isHidden != true else { return }
            if url.pathExtension.lowercased() == "app" {
                // Never recurse into bundles, even malformed ones, or expose embedded helpers.
                var ancestor = url.deletingLastPathComponent()
                while ancestor.path != "/" {
                    if ancestor.pathExtension.lowercased() == "app" { return }
                    ancestor.deleteLastPathComponent()
                }
                guard let entry = application(at: url) else { return }
                applications[entry.definition] = entry
                return
            }
            guard values.isPackage != true,
                  // Do not use .skipsHiddenFiles here: macOS marks some system app
                  // symlinks (including /Applications/Safari.app) hidden even when
                  // the resolved application bundle is visible. The resolved URL's
                  // isHidden value is checked above, after following the symlink.
                  let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for child in children { inspect(child, depth: depth + 1) }
        }
        for root in roots { inspect(root, depth: 0) }
        for url in supplementalURLs { inspect(url, depth: 0) }
        return applications.values.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.definition.url.path < $1.definition.url.path
        }
    }

    private func application(at url: URL) -> CatalogApplication? {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              info["CFBundlePackageType"] as? String == "APPL",
              let bundleID = nonempty(info["CFBundleIdentifier"]), !excludedBundleIDs.contains(bundleID),
              !flag(info["LSBackgroundOnly"]),
              let executable = nonempty(info["CFBundleExecutable"]),
              !executable.contains("/"), executable != ".", executable != "..",
              FileManager.default.isExecutableFile(atPath: contents.appendingPathComponent("MacOS").appendingPathComponent(executable).path) else { return nil }
        var localized: [String: Any] = [:]
        let resources = contents.appendingPathComponent("Resources")
        let available = (try? FileManager.default.contentsOfDirectory(atPath: resources.path))?.filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(6)) } ?? []
        let languages = Bundle.preferredLocalizations(from: available, forPreferences: preferredLanguages)
        for language in languages {
            let file = resources.appendingPathComponent("\(language).lproj/InfoPlist.strings")
            if let data = try? Data(contentsOf: file),
               let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                localized = values
                break
            }
        }
        let name = nonempty(localized["CFBundleDisplayName"]) ?? nonempty(info["CFBundleDisplayName"])
            ?? nonempty(localized["CFBundleName"]) ?? nonempty(info["CFBundleName"])
            ?? url.deletingPathExtension().lastPathComponent
        return CatalogApplication(definition: AppDefinition(url: url, bundleID: bundleID), name: name,
                                  iconData: iconData(at: url), isMenuBarOnly: flag(info["LSUIElement"]))
    }

    private func iconData(at url: URL) -> Data? {
        // Rasterize only a Retina-sized taskbar icon, not every system representation.
        autoreleasepool {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            NSWorkspace.shared.icon(forFile: url.path).draw(in: NSRect(x: 0, y: 0, width: 64, height: 64),
                                                           from: .zero, operation: .copy, fraction: 1)
            return bitmap.representation(using: .png, properties: [:])
        }
    }

    private func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    private func flag(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["true", "yes", "1"].contains(string.lowercased()) }
        return false
    }
}

@MainActor final class ApplicationCatalog {
    private(set) var snapshot: [CatalogApplication] = []
    var changed: (([CatalogApplication]) -> Void)?
    private var generation = 0
    private let scanner: ApplicationCatalogScanner
    init(scanner: ApplicationCatalogScanner = ApplicationCatalogScanner()) { self.scanner = scanner }

    /// Caller may supply known running bundle URLs; this service owns no process monitoring.
    func refresh(supplementalURLs: [URL] = []) async {
        generation += 1
        let request = generation
        let scanner = scanner
        let result = await Task.detached(priority: .utility) { scanner.scan(supplementalURLs: supplementalURLs) }.value
        guard request == generation, !Task.isCancelled else { return }
        snapshot = result
        changed?(snapshot)
    }
    func search(_ query: String) -> [CatalogApplication] { snapshot.filter { $0.matches(query) } }
}

/// Value state shared by the native search UI and focused tests. Selection follows
/// exact bundle identity across refreshes, including equal names and bundle IDs.
struct ApplicationSearchState {
    enum Content: Equatable { case loading, empty, noMatches, results }
    private(set) var applications: [CatalogApplication] = []
    private(set) var results: [CatalogApplication] = []
    private(set) var selected: AppDefinition?
    private(set) var isLoading = false
    var query = "" { didSet { filter() } }
    var content: Content { isLoading && applications.isEmpty ? .loading : applications.isEmpty ? .empty : results.isEmpty ? .noMatches : .results }
    var selection: CatalogApplication? { results.first { $0.definition == selected } }
    mutating func beginRefresh() { isLoading = true }
    mutating func receive(_ values: [CatalogApplication]) { applications = values; isLoading = false; filter() }
    mutating func select(row: Int) { selected = results.indices.contains(row) ? results[row].definition : nil }
    mutating func move(_ delta: Int) {
        guard !results.isEmpty else { selected = nil; return }
        let index = selected.flatMap { id in results.firstIndex { $0.definition == id } } ?? (delta > 0 ? -1 : results.count)
        select(row: min(max(index + delta, 0), results.count - 1))
    }
    private mutating func filter() {
        results = applications.filter { $0.matches(query) }
        if !results.contains(where: { $0.definition == selected }) { selected = results.first?.definition }
    }
}
