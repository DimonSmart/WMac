import AppKit
import ApplicationServices

// Fixture-only verification helper: all external AX messages stay off main.
func closeFocusedFixtureWindow(_ id: InstanceID) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            guard let running = NSRunningApplication(processIdentifier: id.pid), !running.isTerminated,
                  ProcessLifetime.startDate(for: running) == id.startDate else { continuation.resume(returning: false); return }
            let app = AXUIElementCreateApplication(id.pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
                  let focused else { continuation.resume(returning: false); return }
            let window = focused as! AXUIElement
            AXUIElementSetMessagingTimeout(window, 0.2)
            var close: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &close) == .success,
                  let close else { continuation.resume(returning: false); return }
            let button = close as! AXUIElement
            AXUIElementSetMessagingTimeout(button, 0.2)
            continuation.resume(returning: AXUIElementPerformAction(button, kAXPressAction as CFString) == .success)
        }
    }
}

@MainActor func runProbe() async -> Int32 {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL") \(message)")
        if !condition { failures += 1 }
    }
    let args = ProcessInfo.processInfo.arguments
    if args.contains("--catalog") {
        let catalog = ApplicationCatalog()
        await catalog.refresh()
        let query = args.firstIndex(of: "--search").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? ""
        let results = catalog.search(query)
        print("CATALOG count=\(catalog.snapshot.count) matches=\(results.count)")
        for entry in results.prefix(30) { print("\(entry.name) | \(entry.definition.bundleID) | \(entry.definition.url.path)") }
        return catalog.snapshot.isEmpty ? 1 : 0
    }
    guard args.count >= 2 else { print("Usage: WMacProbe /path/to/build/products"); return 2 }
    let products = URL(fileURLWithPath: args[1], isDirectory: true)
    let multi = AppDefinition(url: products.appendingPathComponent("WMacMultiFixture.app"), bundleID: "app.wmac.fixture.multi")
    let single = AppDefinition(url: products.appendingPathComponent("WMacSingleFixture.app"), bundleID: "app.wmac.fixture.single")
    let monitor = ProcessMonitor()
    let launcher = LaunchService(monitor: monitor)
    let ax = AccessibilityService()
    var owned: [Instance] = []
    defer { for instance in owned { _ = monitor.terminate(instance.id) }; monitor.stop() }
    print("REAL GUI INTEGRATION \(ISO8601DateFormatter().string(from: Date()))")
    print("OS \(ProcessInfo.processInfo.operatingSystemVersionString) AX trusted=\(ax.trusted)")
    if args.contains("--require-ax") || args.contains("--require-no-ax") {
        print("AX client: WMacProbe executable=\(CommandLine.arguments[0]), pid=\(ProcessInfo.processInfo.processIdentifier). AXIsProcessTrusted checks this process; WMac.app has a separate Accessibility identity.")
    }
    if args.contains("--require-no-ax") && ax.trusted { print("NOT VERIFIED: no-AX scenario requires running from a host without Accessibility grant; current host is already trusted. No TCC changes made."); return 3 }
    if args.contains("--require-ax") && !ax.trusted { print("NOT VERIFIED: WMacProbe does not have Accessibility access. Grant the WMacProbe entry (or the responsible terminal shown by System Settings); WMac.app access is separate. No TCC changes made."); return 3 }
    func description(_ result: LaunchResult) -> String {
        switch result {
        case .success(let instance): return "success PID \(instance.id.pid)"
        case .accessorySuccess(let pid): return "accessory success PID \(pid)"
        case .error(let message): return "error: \(message)"
        case .unconfirmed(let message): return "unconfirmed: \(message)"
        }
    }
    func confirmed(_ result: LaunchResult, _ label: String) -> Instance? {
        switch result {
        case .success(let instance): print("SUCCESS \(label) pid=\(instance.id.pid) start=\(instance.id.startDate)"); owned.append(instance); return instance
        case .accessorySuccess(let pid): print("ERROR \(label) expected taskbar instance, got menu-bar PID \(pid)"); return nil
        case .error(let message): print("ERROR \(label): \(message)"); return nil
        case .unconfirmed(let message): print("UNCONFIRMED \(label): \(message)"); return nil
        }
    }
    guard let first = confirmed(await launcher.launch(multi), "multi 1") else { check(false, "first real GUI launch"); return 1 }
    // Concurrent requests have separate callbacks and baselines.
    async let secondResult = launcher.launch(multi)
    async let thirdResult = launcher.launch(multi)
    let (r2, r3) = await (secondResult, thirdResult)
    guard let second = confirmed(r2, "multi 2"), let third = confirmed(r3, "multi 3") else { check(false, "concurrent GUI launches"); return 1 }
    let instances = [first, second, third]
    // Both launches request foreground activation asynchronously. Let their
    // queued activation events settle before issuing unrelated PID switches.
    try? await Task.sleep(for: .milliseconds(700))
    for instance in instances {
        let live = NSRunningApplication(processIdentifier: instance.id.pid)
        print("IDENTITY pid=\(instance.id.pid) expected=\(instance.id.startDate.timeIntervalSince1970) actual=\(live.flatMap { ProcessLifetime.startDate(for: $0)?.timeIntervalSince1970 } ?? -1) policy=\(live?.activationPolicy.rawValue ?? -1) terminated=\(live?.isTerminated ?? true)")
    }
    check(Set(instances.map(\.id.pid)).count == 3 && instances.allSatisfy { monitor.running($0.id) != nil }, "three simultaneous distinct regular GUI PIDs")
    for instance in instances {
        let requested = monitor.activate(instance.id)
        let deadline = Date().addingTimeInterval(2)
        repeat {
            try? await Task.sleep(for: .milliseconds(100))
        } while NSWorkspace.shared.frontmostApplication?.processIdentifier != instance.id.pid && Date() < deadline
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        check(requested && front == instance.id.pid, "activate exact PID \(instance.id.pid) request=\(requested), observed frontmost=\(front ?? -1)")
    }
    let forgedID = InstanceID(pid: first.id.pid, startDate: first.id.startDate.addingTimeInterval(-1))
    check(monitor.running(forgedID) == nil, "PID reuse/stale launch identity rejected")
    if ax.trusted {
        if case .unavailable = await ax.windows(for: forgedID) { check(true, "stale process identity cannot enumerate another lifetime's AX windows") }
        else { check(false, "stale process AX windows must be unavailable") }
    }
    let observation = await ax.observe(first.id) { print("AX OBSERVER: fixture window state changed") }
    if ax.trusted { check(observation != nil, "public AXObserver registered for fixture PID") }
    defer { withExtendedLifetime(observation) {} }
    let axResult = await ax.windows(for: first.id)
    switch axResult {
    case .unavailable(let message, _):
        check(!ax.trusted, "without AX, window actions are limited: \(message)")
        print("NOT VERIFIED: AX window enumeration/restore/raise requires an explicit user Accessibility grant to WMacProbe (or the responsible terminal shown by System Settings). WMac.app access is separate. No grant changed.")
    case .windows(let windows, let diagnostics):
        check(windows.count == 2 && windows.allSatisfy { $0.instance == first.id }, "two standard AX windows belong to exact PID \(first.id.pid)")
        check(diagnostics.status == .complete, "probe fixture enumeration is complete")
        if let window = windows.first {
            let selected = await ax.select(window)
            check(selected.outcome == .restored && selected.activationAccepted, "service selects and restores exact AX window")
            try? await Task.sleep(for: .milliseconds(350))
            if case .windows(let focused, _) = await ax.windows(for: first.id) {
                check(focused.first(where: \.isFocused)?.id == window.id, "focus follows selected AX identity")
            } else { check(false, "selected state must remain enumerable") }
            print("SELECT RESULT \(selected.message)")
            let minimized = await ax.switchTo(first.id, minimizeIfActive: true, isActive: true)
            print("MINIMIZE RESULT \(minimized.message)")
            check(minimized.outcome == .minimized, "service minimizes manageable focused window")
            try? await Task.sleep(for: .milliseconds(250))
            if case .windows(let values, _) = await ax.windows(for: first.id) {
                check(values.first(where: { $0.id == window.id })?.isMinimized == true, "real minimized state read back")
            } else { check(false, "minimized state must remain enumerable") }
            let restored = await ax.switchTo(first.id, minimizeIfActive: true, isActive: true)
            print("RESTORE RESULT \(restored.message)")
            try? await Task.sleep(for: .milliseconds(300))
            if case .windows(let values, _) = await ax.windows(for: first.id) {
                check(restored.outcome == .restored && values.first(where: { $0.id == window.id })?.isMinimized == false && NSWorkspace.shared.frontmostApplication?.processIdentifier == first.id.pid,
                      "subsequent toggle restores same window and activates exact PID")
            } else { check(false, "restored state must remain enumerable") }
            if let other = windows.last, other.id != window.id {
                print("OTHER RESULT \((await ax.select(other)).message)")
                try? await Task.sleep(for: .milliseconds(250))
                _ = monitor.activate(third.id)
                try? await Task.sleep(for: .milliseconds(250))
                print("SWITCH RESULT \((await ax.switchTo(first.id)).message)")
                try? await Task.sleep(for: .milliseconds(300))
                if case .windows(let values, _) = await ax.windows(for: first.id) {
                    check(values.first(where: \.isFocused)?.id == other.id, "ordinary switch restores last-active window among multiple windows")
                    check(await closeFocusedFixtureWindow(first.id), "close fixture's focused actual AX window")
                    try? await Task.sleep(for: .milliseconds(300))
                    if case .windows(let remaining, _) = await ax.windows(for: first.id) {
                        check(remaining.count == 1 && !remaining.contains(where: { $0.id == other.id }), "destroyed window disappears from snapshot")
                    } else { check(false, "surviving window remains enumerable") }
                    let vanished = await ax.select(other)
                    check(vanished.outcome == .unavailable && !vanished.activationAccepted,
                          "vanished explicit window selection never activates an arbitrary fallback window")
                }
            }
        }
    }
    check(monitor.terminate(second.id), "terminate second PID \(second.id.pid)")
    try? await Task.sleep(for: .milliseconds(700))
    check(monitor.running(second.id) == nil && monitor.running(first.id) != nil && monitor.running(third.id) != nil,
          "second exited; first \(first.id.pid) and third \(third.id.pid) survive")
    let staleWindowResult = await ax.switchTo(second.id)
    check(staleWindowResult.outcome == .unavailable && !staleWindowResult.activationAccepted, "terminated target cannot receive window or process action")
    for _ in 0..<8 { _ = await ax.observe(first.id) {} }
    check(true, "repeated observer registration and disposal completed")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WMacProbe-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let lock = directory.appendingPathComponent("single.lock").path
    let refusal = directory.appendingPathComponent("refusal.txt").path
    let singleArgs = ["--lock", lock, "--refusal", refusal]
    if let initial = confirmed(await launcher.launch(single, arguments: singleArgs), "single initial") {
        let rejected = await launcher.launch(single, arguments: singleArgs, timeout: 3)
        print("SINGLE SECOND RESULT \(description(rejected))")
        let evidence = (try? String(contentsOfFile: refusal, encoding: .utf8)) ?? ""
        print("FIXTURE REFUSAL EVIDENCE \(evidence.trimmingCharacters(in: .whitespacesAndNewlines))")
        if case .success = rejected { check(false, "single-instance refusal must never report success") }
        else { check(evidence.contains("reason=fixture-exclusive-lock") && monitor.instances(of: single).count == 1 && monitor.running(initial.id) != nil,
                     "controlled single-instance refusal is established by fixture evidence; no false success") }
    } else { check(false, "single initial GUI process") }
    let immediate = await launcher.launch(multi, arguments: ["--exit-immediately"], timeout: 2)
    print("IMMEDIATE EXIT RESULT \(description(immediate))")
    if case .success = immediate { check(false, "immediate fixture exit must not report success") }
    else { check(true, "immediate fixture exit returns error/unconfirmed") }
    let missing = AppDefinition(url: products.appendingPathComponent("Missing.app"), bundleID: "app.wmac.missing")
    if case .error = await launcher.launch(missing) { check(true, "missing bundle returns error") }
    else { check(false, "missing bundle returns error") }
    let wmac = AppDefinition(url: products.appendingPathComponent("WMac.app"), bundleID: "app.wmac.WMac")
    check(confirmed(await launcher.launch(wmac, arguments: ["--diagnostics"]), "WMac diagnostic app smoke") != nil, "native WMac diagnostic app opens as a regular GUI process")
    print("RESULT failures=\(failures); AX \(ax.trusted ? "exercised" : "NOT VERIFIED (permission absent)")")
    return failures == 0 ? 0 : 1
}
Task { @MainActor in exit(await runProbe()) }
RunLoop.main.run()
