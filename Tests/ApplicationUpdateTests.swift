import Foundation

@MainActor func testApplicationUpdates(_ check: (Bool, String) -> Void) throws {
    check(ReleaseVersion("v1.10.0")! > ReleaseVersion("1.9.9")!, "updates compare versions numerically")
    check(ReleaseVersion("1.2") == ReleaseVersion("1.2.0"), "two-component release versions normalize")
    for invalid in ["", "1", "1.2.3-beta", "1..2", "1.2.3.4", "-1.2.3", "1.2.9999999999999999999999999"] {
        check(ReleaseVersion(invalid) == nil, "invalid release version rejected: \(invalid)")
    }
    let hash = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    func release(url: String = "https://github.com/DimonSmart/WMac/releases/download/v1.2.3/WMac-1.2.3-2.dmg", digest: String? = hash, draft: Bool = false, prerelease: Bool = false) -> ApplicationRelease {
        ApplicationRelease(tag_name: "v1.2.3", html_url: URL(string: "https://github.com/DimonSmart/WMac/releases/tag/v1.2.3")!, draft: draft, prerelease: prerelease, assets: [.init(name: "WMac-1.2.3-2.dmg", browser_download_url: URL(string: url)!, digest: digest)])
    }
    check(release().valid && release().package != nil, "official stable DMG with digest is installable")
    check(!release(draft: true).valid && !release(prerelease: true).valid, "draft and prerelease are excluded")
    for url in ["http://github.com/DimonSmart/WMac/releases/download/a.dmg", "https://github.com.evil.test/DimonSmart/WMac/releases/download/a.dmg", "https://github.com/Other/WMac/releases/download/a.dmg", "https://github.com/DimonSmart/WMac/evil/a.dmg"] {
        check(release(url: url).package == nil, "untrusted update URL rejected")
    }
    check(release(digest: nil).package == nil && release(digest: "sha256:abc").package == nil, "missing or malformed digest rejects package")
    check(ApplicationUpdateService.verifyDigest(Data("abc".utf8), expected: hash), "download checksum matches known SHA-256 vector")
    check(!ApplicationUpdateService.verifyDigest(Data("corrupt".utf8), expected: hash), "damaged update is rejected")
    check(!ApplicationUpdateService.supported(URL(fileURLWithPath: "/Volumes/WMac/WMac.app")) &&
          !ApplicationUpdateService.supported(URL(fileURLWithPath: "/tmp/WMac.app")), "disk image and development locations cannot self-replace")
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("WMacUpdateTests-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let app = root.appendingPathComponent("WMac.app")
    let stage = root.appendingPathComponent("stage.app")
    let settings = root.appendingPathComponent("settings.json")
    try Data("settings-and-pins".utf8).write(to: settings)
    try Data("old".utf8).write(to: app)
    try Data("new".utf8).write(to: stage)
    let backup = try ApplicationUpdateService.replace(staged: stage, destination: app)
    check(try Data(contentsOf: app) == Data("new".utf8) && Data(contentsOf: backup) == Data("old".utf8), "replacement retains original as recovery copy")
    do {
        _ = try ApplicationUpdateService.replace(staged: root.appendingPathComponent("missing.app"), destination: app)
        check(false, "failed replacement must throw")
    } catch {
        check(try Data(contentsOf: app) == Data("new".utf8), "failed replacement restores installed app")
    }
    check(try Data(contentsOf: settings) == Data("settings-and-pins".utf8), "replacement does not modify user data")
}

@MainActor func testUpdateDiskImage(_ check: (Bool, String) -> Void) async throws {
    guard let path = ProcessInfo.processInfo.environment["WMAC_UPDATE_TEST_DMG"] else { return }
    let image = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: image)
    // The fixture is produced by the repository's ordinary verified release script.
    let checksumFile = image.deletingLastPathComponent().appendingPathComponent("SHA256.txt")
    let checksum = try String(contentsOf: checksumFile, encoding: .utf8).split(separator: " ")[0]
    let digest = "sha256:" + checksum
    let version = image.deletingPathExtension().lastPathComponent.split(separator: "-")[1]
    let asset = ApplicationRelease.Asset(name: image.lastPathComponent, browser_download_url: URL(string: "https://github.com/DimonSmart/WMac/releases/download/v\(version)/\(image.lastPathComponent)")!, digest: digest)
    let release = ApplicationRelease(tag_name: "v\(version)", html_url: URL(string: "https://github.com/DimonSmart/WMac/releases/tag/v\(version)")!, draft: false, prerelease: false, assets: [asset])
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("WMacDMGTests-\(UUID())")
    let destination = root.appendingPathComponent("WMac.app")
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let marker = destination.appendingPathComponent("previous-copy")
    try Data("original".utf8).write(to: marker)
    let service = ApplicationUpdateService()
    let backup = try await service.installImage(image, release: release, destination: destination, expectedDigest: digest)
    check(fm.fileExists(atPath: destination.appendingPathComponent("Contents/MacOS/WMac").path) &&
          fm.fileExists(atPath: backup.appendingPathComponent("previous-copy").path), "real signed DMG installs with original retained")
    try await service.restore(backup: backup, destination: destination)
    check(try Data(contentsOf: marker) == Data("original".utf8), "relaunch failure rollback restores original from real DMG installation")
    let wrongVersion = ApplicationRelease(tag_name: "v99.0.0", html_url: release.html_url, draft: false, prerelease: false, assets: [asset])
    do {
        _ = try await service.installImage(image, release: wrongVersion, destination: destination, expectedDigest: digest)
        check(false, "bundle version must match release metadata")
    } catch {
        check(fm.fileExists(atPath: marker.path), "mismatched signed bundle version leaves original untouched")
    }
    let corrupt = root.appendingPathComponent("corrupt.dmg")
    try data.prefix(100).write(to: corrupt)
    do {
        _ = try await service.installImage(corrupt, release: release, destination: destination, expectedDigest: digest)
        check(false, "corrupt image must fail before replacement")
    } catch {
        check(fm.fileExists(atPath: marker.path), "corrupt DMG leaves original app untouched")
    }
}
