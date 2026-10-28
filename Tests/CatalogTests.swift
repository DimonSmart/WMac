import AppKit
import Darwin

@MainActor func testApplicationCatalog(_ check: (Bool, String) -> Void) async throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("WMacCatalogTests-\(UUID().uuidString)")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }
    @discardableResult func bundle(_ path: String, id: String = "test.catalog.shared", extra: [String: Any] = [:], localized: [String: String]? = nil) throws -> URL {
        let url = directory.appendingPathComponent(path)
        let contents = url.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL", "CFBundleExecutable": "fixture"]
        info.merge(extra) { _, new in new }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/fixture")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        if let localized {
            let folder = contents.appendingPathComponent("Resources/ru.lproj")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: localized, format: .xml, options: 0).write(to: folder.appendingPathComponent("InfoPlist.strings"))
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }
    let first = try bundle("Applications/Vendor/First.app", extra: ["CFBundleDisplayName": "English Name"], localized: ["CFBundleDisplayName": "Ёлка Редактор"])
    let second = try bundle("Applications/Other.app", extra: ["CFBundleName": "Café Editor"])
    let fallback = try bundle("Applications/Filename.app", id: "test.fallback", extra: ["CFBundleDisplayName": "  "])
    let agent = try bundle("Applications/Agent.app", extra: ["LSUIElement": true])
    try bundle("Applications/Background.app", extra: ["LSBackgroundOnly": "YES"])
    let malformed = try bundle("Applications/Malformed.app", extra: ["CFBundleExecutable": "missing"])
    try bundle("Applications/Broken.app", extra: ["CFBundleIdentifier": ""])
    try bundle("Applications/Corrupt.app")
    try Data("bad plist".utf8).write(to: directory.appendingPathComponent("Applications/Corrupt.app/Contents/Info.plist"))
    let helper = try bundle("Applications/Vendor/First.app/Contents/Helpers/Hidden.app")
    try bundle("Applications/Malformed.app/Contents/Helpers/Hidden.app")
    let supplemental = try bundle("Outside/Extra.app", id: "test.extra")
    let hiddenAliasTarget = try bundle("Targets/HiddenAliasTarget.app", id: "test.hidden-alias")
    let alias = directory.appendingPathComponent("Applications/Alias.app")
    try fm.createSymbolicLink(at: alias, withDestinationURL: first)
    let hiddenAlias = directory.appendingPathComponent("Applications/HiddenAlias.app")
    try fm.createSymbolicLink(at: hiddenAlias, withDestinationURL: hiddenAliasTarget)
    check(lchflags(hiddenAlias.path, UInt32(UF_HIDDEN)) == 0, "fixture hides only the application symlink, like the Safari system alias")
    var scanner = ApplicationCatalogScanner()
    scanner.roots = [directory.appendingPathComponent("Applications"), directory.appendingPathComponent("missing"), directory.appendingPathComponent("Applications/Vendor")]
    scanner.preferredLanguages = ["ru", "en"]
    let catalog = ApplicationCatalog(scanner: scanner)
    var publications = 0
    catalog.changed = { _ in publications += 1 }
    await catalog.refresh(supplementalURLs: [first, helper, supplemental, malformed])
    check(publications == 1 && catalog.snapshot.count == 6, "catalog publishes one immutable snapshot; nested discovery, hidden app aliases, menu-bar apps, missing roots, malformed/background apps and embedded helpers handled")
    check(Set(catalog.snapshot.map(\.definition)) == Set([AppDefinition(url: first, bundleID: "test.catalog.shared"), AppDefinition(url: second, bundleID: "test.catalog.shared"), AppDefinition(url: fallback, bundleID: "test.fallback"), AppDefinition(url: agent, bundleID: "test.catalog.shared"), AppDefinition(url: supplemental, bundleID: "test.extra"), AppDefinition(url: hiddenAliasTarget, bundleID: "test.hidden-alias")]), "catalog canonical paths deduplicate aliases while same bundle ID at distinct paths remains selectable")
    check(catalog.snapshot.first { $0.definition.url == agent }?.isMenuBarOnly == true, "menu-bar app is classified for launch-only behavior")
    let pinStore = PinStore(url: directory.appendingPathComponent("pins.json"))
    let menuBarPin = await pinStore.prepare(url: agent)
    check(menuBarPin == nil, "menu-bar apps are available to launch but remain ineligible for Finder pin preparation")
    check(catalog.snapshot.first { $0.definition.url == first }?.name == "Ёлка Редактор", "catalog prefers localized display name")
    check(catalog.snapshot.first { $0.definition.url == second }?.name == "Café Editor" && catalog.snapshot.first { $0.definition.url == fallback }?.name == "Filename", "catalog falls back through bundle name to filename")
    check(catalog.search("елка РЕД").map(\.definition.url) == [first], "Russian search ignores case and diacritics and matches multiple terms")
    check(catalog.search("CAFE editor").map(\.definition.url) == [second] && catalog.search("absent").isEmpty, "English name search handles diacritics and empty results")
    check(catalog.search("  ").count == 6 && catalog.snapshot.allSatisfy { $0.icon.size.width > 0 }, "empty search returns all apps including menu-bar apps with usable system icon fallbacks")
    check(catalog.snapshot.allSatisfy { entry in
        guard let data = entry.iconData, let bitmap = NSBitmapImageRep(data: data) else { return false }
        return bitmap.pixelsWide == 64 && bitmap.pixelsHigh == 64
    }, "catalog stores only bounded 64-pixel system icons")
    var search = ApplicationSearchState()
    check(search.content == .empty && search.selection == nil, "search starts with an honest empty state")
    search.beginRefresh()
    check(search.content == .loading, "first asynchronous scan has a loading state")
    search.receive(catalog.snapshot)
    check(search.content == .results && search.selection != nil && search.applications.contains(where: { $0.isMenuBarOnly }) && search.applications.contains(where: { $0.definition == AppDefinition(url: hiddenAliasTarget, bundleID: "test.hidden-alias") }), "published applications populate search, including menu-bar apps and apps behind hidden symlinks")
    let secondDefinition = AppDefinition(url: second, bundleID: "test.catalog.shared")
    search.select(row: search.results.firstIndex { $0.definition == secondDefinition }!)
    check(search.selection?.definition == secondDefinition, "search selection preserves exact same-bundle-ID path")
    search.beginRefresh(); search.receive(catalog.snapshot.reversed())
    check(search.selection?.definition == secondDefinition && !search.isLoading, "asynchronous refresh and reorder retain exact selection")
    search.query = "impossible-search-term"
    check(search.content == .noMatches && search.selection == nil, "no-match state cannot launch a stale selection")
    search.query = "елка РЕД"
    check(search.selection?.definition.url == first && search.results.count == 1, "search filtering selects exact Russian match")
    search.query = ""
    search.move(1); let moved = search.selection?.definition
    search.move(-1)
    check(moved != search.selection?.definition, "keyboard result navigation changes exact selected identity")
    search.receive([])
    check(search.content == .empty && search.selection == nil, "empty asynchronous publication clears stale results")
    let beforeCancellation = publications
    let cancelled = Task { @MainActor in await catalog.refresh() }
    cancelled.cancel(); await cancelled.value
    check(publications == beforeCancellation, "cancelled scan never publishes an obsolete snapshot")
    let earlier = Task { @MainActor in await catalog.refresh(supplementalURLs: [supplemental]) }
    let latest = Task { @MainActor in await catalog.refresh(supplementalURLs: [supplemental]) }
    await earlier.value; await latest.value
    check(publications == beforeCancellation + 1, "overlapping catalog refreshes publish only the latest generation")
    try fm.removeItem(at: second)
    await catalog.refresh()
    check(catalog.snapshot.count == 4 && !catalog.snapshot.contains { $0.definition.url == second } && catalog.snapshot.contains { $0.definition.url == hiddenAliasTarget }, "catalog refresh removes vanished bundles and previous supplemental entries while retaining menu-bar apps and hidden-alias targets")
}
