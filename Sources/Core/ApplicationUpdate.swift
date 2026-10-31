import Foundation
import CryptoKit

struct ReleaseVersion: Comparable, Sendable {
    let parts: [Int]
    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(fields.count), fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              fields.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = fields.map { Int($0)! } + (fields.count == 2 ? [0] : [])
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct ApplicationRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browser_download_url: URL
        let digest: String?
    }
    let tag_name: String
    let html_url: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    var version: ReleaseVersion? { ReleaseVersion(tag_name) }
    static func official(_ url: URL, prefix: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil &&
        url.port == nil && url.path.hasPrefix("/DimonSmart/WMac/" + prefix)
    }
    var valid: Bool { !draft && !prerelease && version != nil && Self.official(html_url, prefix: "releases/tag/") }
    var package: Asset? {
        let matches = assets.filter { asset in
            guard asset.name.hasPrefix("WMac-"), asset.name.hasSuffix(".dmg"),
                  Self.official(asset.browser_download_url, prefix: "releases/download/"),
                  let digest = asset.digest, digest.hasPrefix("sha256:") else { return false }
            let hash = digest.dropFirst(7)
            return hash.count == 64 && hash.allSatisfy { $0.isASCII && $0.isHexDigit }
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

enum UpdateError: Error { case unavailable, invalidPackage, unsupportedLocation }

// Disk image operations run on this actor, never on the AppKit actor.
actor ApplicationUpdateService {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config)
    }
    func latest() async throws -> ApplicationRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/DimonSmart/WMac/releases/latest")!)
        request.setValue("WMac", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.unavailable }
        let release = try JSONDecoder().decode(ApplicationRelease.self, from: data)
        guard release.valid else { throw UpdateError.unavailable }
        return release
    }
    static func supported(_ destination: URL) -> Bool {
        let path = destination.standardizedFileURL.path
        let roots = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        return destination.lastPathComponent == "WMac.app" && roots.contains(destination.deletingLastPathComponent().path) &&
            path == destination.resolvingSymlinksInPath().path &&
            FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) &&
            FileManager.default.isWritableFile(atPath: destination.path)
    }
    static func verifyDigest(_ data: Data, expected: String) -> Bool {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expected.lowercased()
    }
    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.invalidPackage }
    }
    func install(_ release: ApplicationRelease, destination: URL) async throws -> URL {
        guard Self.supported(destination) else { throw UpdateError.unsupportedLocation }
        guard release.valid, let asset = release.package, let expected = asset.digest else { throw UpdateError.invalidPackage }
        let (download, response) = try await session.download(from: asset.browser_download_url)
        defer { try? FileManager.default.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.unavailable }
        return try installImage(download, release: release, destination: destination, expectedDigest: expected)
    }
    // Internal seam also lets integration checks exercise real signed DMGs in a disposable folder.
    func installImage(_ download: URL, release: ApplicationRelease, destination: URL, expectedDigest: String) throws -> URL {
        guard release.valid, release.package?.digest == expectedDigest,
              try Self.verifyDigest(Data(contentsOf: download, options: .mappedIfSafe), expected: expectedDigest) else { throw UpdateError.invalidPackage }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("WMacUpdate-\(UUID())")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let image = temporary.appendingPathComponent("update.dmg")
        try fm.copyItem(at: download, to: image)
        let mount = temporary.appendingPathComponent("volume")
        try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path]) }
        let source = mount.appendingPathComponent("WMac.app")
        let infoURL = source.appendingPathComponent("Contents/Info.plist")
        guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "app.wmac.WMac",
              let version = info["CFBundleShortVersionString"] as? String,
              ReleaseVersion(version) == release.version,
              let minimum = info["LSMinimumSystemVersion"] as? String,
              minimum.compare(ProcessInfo.processInfo.operatingSystemVersionStringForUpdate, options: .numeric) != .orderedDescending else { throw UpdateError.invalidPackage }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path])
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".WMacUpdate-\(UUID()).app")
        defer { try? fm.removeItem(at: stage) }
        try fm.copyItem(at: source, to: stage)
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", stage.path])
        return try Self.replace(staged: stage, destination: destination)
    }
    // Keep the backup next to the app so both renames stay on the same filesystem.
    static func replace(staged: URL, destination: URL) throws -> URL {
        let fm = FileManager.default
        let backup = destination.deletingLastPathComponent().appendingPathComponent(".WMacPrevious-\(UUID()).app")
        try fm.moveItem(at: destination, to: backup)
        do { try fm.moveItem(at: staged, to: destination) }
        catch {
            try fm.moveItem(at: backup, to: destination)
            throw error
        }
        return backup
    }
    func restore(backup: URL, destination: URL) throws {
        let failed = destination.deletingLastPathComponent().appendingPathComponent(".WMacFailed-\(UUID()).app")
        try FileManager.default.moveItem(at: destination, to: failed)
        do { try FileManager.default.moveItem(at: backup, to: destination) }
        catch {
            try? FileManager.default.moveItem(at: failed, to: destination)
            throw error
        }
        try? FileManager.default.removeItem(at: failed)
    }
}

private extension ProcessInfo {
    var operatingSystemVersionStringForUpdate: String {
        let v = operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
