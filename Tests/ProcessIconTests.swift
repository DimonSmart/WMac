import AppKit

@MainActor func testCommandLineProcessIcon(_ check: (Bool, String) -> Void) async throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("WMacProcessIconTests-\(UUID().uuidString)")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("CommandLineGUI")
    let fixture = URL(fileURLWithPath: fm.currentDirectoryPath)
        .appendingPathComponent(".build/products/Debug/WMacMultiFixture.app/Contents/MacOS/WMacMultiFixture")
    try fm.copyItem(at: fixture, to: executable)
    let process = Process()
    process.executableURL = executable
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    let monitor = ProcessMonitor()
    defer { monitor.stop() }
    let deadline = Date().addingTimeInterval(5)
    while !monitor.snapshot.contains(where: { $0.id.pid == process.processIdentifier }), Date() < deadline {
        try await Task.sleep(for: .milliseconds(100))
        monitor.refresh()
    }
    guard let instance = monitor.snapshot.first(where: { $0.id.pid == process.processIdentifier }) else {
        check(false, "command-line GUI process without a bundle is discovered")
        return
    }
    let running = monitor.running(instance.id)
    check(running?.launchDate == nil && instance.definition == nil,
          "command-line GUI fixture exercises missing LaunchServices date and app definition")
    let coordinator = TaskbarCoordinator()
    coordinator.apply(monitor.snapshot, active: instance.id)
    let buttons = coordinator.snapshot.buttons.filter { $0.instance?.id == instance.id }
    check(buttons.count == 1 && buttons.first?.pinID == nil && buttons.first?.isActive == true,
          "command-line GUI has one temporary button bound to its exact lifetime")
    guard let button = buttons.first, let source = PanelIconSource(button) else {
        check(false, "bundleless process has an icon source")
        return
    }
    check(source == .instance(instance.id), "bundleless icon cache uses process lifetime instead of an app definition")
    let icons = PanelIcons()
    let data = await icons.icon(source)
    let bitmap = data.flatMap(NSBitmapImageRep.init(data:))
    check(bitmap?.pixelsWide == 96 && bitmap?.pixelsHigh == 96,
          "bundleless process supplies a bounded system icon without using the WMac icon")
    check(PanelIcons.fallback !== NSImage(named: NSImage.applicationIconName),
          "missing icons use a neutral symbol instead of the host application's icon")
    let stale = InstanceID(pid: instance.id.pid, startDate: instance.id.startDate.addingTimeInterval(-1))
    let staleIcon = await icons.icon(.instance(stale))
    check(staleIcon == nil, "icon lookup rejects another lifetime with the same PID")
    process.terminate()
    let exitDeadline = Date().addingTimeInterval(5)
    while process.isRunning, Date() < exitDeadline { try await Task.sleep(for: .milliseconds(100)) }
    monitor.refresh()
    let terminatedIcon = await icons.icon(source)
    check(!monitor.snapshot.contains(where: { $0.id == instance.id }) && terminatedIcon == nil,
          "terminated command-line process loses both its button and its icon source")
}
