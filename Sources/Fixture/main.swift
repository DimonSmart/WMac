import AppKit
import Darwin

@MainActor final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var lockDescriptor: Int32 = -1
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--exit-immediately") { exit(0) }
        #if SINGLE_INSTANCE
        if let index = args.firstIndex(of: "--lock"), index + 1 < args.count {
            lockDescriptor = open(args[index + 1], O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard lockDescriptor >= 0 else { exit(72) }
            if flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
                if let report = args.firstIndex(of: "--refusal"), report + 1 < args.count {
                    let evidence = "refused pid=\(getpid()) reason=fixture-exclusive-lock\n"
                    try? evidence.write(toFile: args[report + 1], atomically: true, encoding: .utf8)
                }
                exit(73)
            }
        } else { exit(74) }
        #endif
        for number in 1...2 {
            let position = args.contains("--overlap") ? 1 : number
            let window = NSWindow(contentRect: NSRect(x: 180 + position * 45, y: 240 + position * 35, width: 420, height: 180),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            let contentTitle = "WMac Fixture PID \(getpid()) Window \(number)"
            window.title = args.contains("--same-title") ? "WMac Fixture PID \(getpid()) Same Title" : contentTitle
            // Keep distinct visible contents even when matching evidence is identical.
            let label = NSTextField(labelWithString: contentTitle)
            label.frame = NSRect(x: 24, y: 70, width: 380, height: 30)
            window.contentView?.addSubview(label)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
