import AppKit

struct AppDefinition: Hashable, Codable, Sendable {
    let url: URL
    let bundleID: String
    init(url: URL, bundleID: String) {
        self.url = url.resolvingSymlinksInPath().standardizedFileURL
        self.bundleID = bundleID
    }
    func matches(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == bundleID && app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == url
    }
}
struct InstanceID: Hashable, Sendable {
    let pid: pid_t
    let launchDate: Date
}
struct Instance: Identifiable, Sendable {
    let id: InstanceID
    let name: String
    let url: URL?
    let bundleID: String
    var definition: AppDefinition? {
        guard let url, !bundleID.isEmpty else { return nil }
        return AppDefinition(url: url, bundleID: bundleID)
    }
}
@MainActor
final class ProcessMonitor {
    private var tokens: [NSObjectProtocol] = []
    private var timer: Timer?
    private(set) var snapshot: [Instance] = []
    private(set) var activeInstance: InstanceID?
    var changed: (([Instance]) -> Void)?
    init(interval: TimeInterval = 10) {
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                      NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification,
                      NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                      NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            tokens.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: max(interval, 5), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }
    func refresh() {
        snapshot = NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, app.activationPolicy == .regular,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let date = app.launchDate else { return nil }
            return Instance(id: InstanceID(pid: app.processIdentifier, launchDate: date),
                            name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "Application \(app.processIdentifier)",
                            url: app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL,
                            bundleID: app.bundleIdentifier ?? "")
        }.sorted { $0.id.launchDate < $1.id.launchDate }
        activeInstance = snapshot.first { $0.id.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier }?.id
        changed?(snapshot)
    }
    func instances(of definition: AppDefinition) -> [Instance] {
        refresh()
        return snapshot.filter { $0.url == definition.url && $0.bundleID == definition.bundleID }
    }
    func running(_ id: InstanceID) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: id.pid),
              !app.isTerminated, app.launchDate == id.launchDate, app.activationPolicy == .regular else { return nil }
        return app
    }
    func activate(_ id: InstanceID) -> Bool {
        guard let app = running(id) else { return false }
        NSApplication.shared.yieldActivation(to: app)
        return app.activate(options: [])
    }
    func terminate(_ id: InstanceID) -> Bool { running(id)?.terminate() ?? false }
    func stop() {
        timer?.invalidate()
        timer = nil
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        tokens.removeAll()
    }
}
