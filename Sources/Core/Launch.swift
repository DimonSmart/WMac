import AppKit

enum LaunchResult {
    case success(Instance)
    case error(String)
    case unconfirmed(String)
}
@MainActor
final class LaunchService {
    private let monitor: ProcessMonitor
    // Each request owns its callback and baseline. No shared in-flight result.
    init(monitor: ProcessMonitor) { self.monitor = monitor }
    /// Ordinary idle-pin launch may reuse an existing process. Independent requests
    /// retain their stricter new-PID contract below.
    func open(_ definition: AppDefinition, timeout: TimeInterval = 6) async -> LaunchResult {
        guard await Task.detached(operation: { Bundle(url: definition.url)?.bundleIdentifier == definition.bundleID }).value else {
            return .error("Application bundle is missing or its identity changed")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        let callback = CallbackState()
        NSWorkspace.shared.openApplication(at: definition.url, configuration: configuration) { app, error in
            Task { @MainActor in callback.completed = true; callback.app = app; callback.error = error?.localizedDescription }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if callback.completed {
                if let error = callback.error { return .error(error) }
                if let app = callback.app, definition.matches(app),
                   let instance = monitor.instances(of: definition).first(where: { $0.id.pid == app.processIdentifier }),
                   monitor.running(instance.id) != nil { return .success(instance) }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .unconfirmed("Ordinary launch could not be confirmed")
    }
    func launch(_ definition: AppDefinition, arguments: [String] = [], timeout: TimeInterval = 6) async -> LaunchResult {
        guard await Task.detached(operation: { Bundle(url: definition.url)?.bundleIdentifier == definition.bundleID }).value else {
            return .error("Application bundle is missing or its identity changed")
        }
        let baseline = Set(monitor.instances(of: definition).map(\.id.pid))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = arguments
        let callback = CallbackState()
        NSWorkspace.shared.openApplication(at: definition.url, configuration: configuration) { app, error in
            Task { @MainActor in callback.completed = true; callback.app = app; callback.error = error?.localizedDescription }
        }
        let deadline = Date().addingTimeInterval(max(0.2, timeout))
        while Date() < deadline {
            if callback.completed {
                if let error = callback.error { return .error(error) }
                if let app = callback.app, app.isFinishedLaunching, definition.matches(app), !baseline.contains(app.processIdentifier),
                   let instance = monitor.instances(of: definition).first(where: { $0.id.pid == app.processIdentifier }),
                   !app.isTerminated {
                    // Reject immediate exits; observe a second real snapshot after settling.
                    try? await Task.sleep(for: .milliseconds(350))
                    if monitor.instances(of: definition).contains(where: { $0.id == instance.id }), monitor.running(instance.id) != nil {
                        _ = monitor.activate(instance.id)
                        return .success(instance)
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .unconfirmed("No new running regular GUI PID matching the exact bundle URL was confirmed within \(timeout)s")
    }
}
@MainActor private final class CallbackState {
    var completed = false
    var app: NSRunningApplication?
    var error: String?
}
