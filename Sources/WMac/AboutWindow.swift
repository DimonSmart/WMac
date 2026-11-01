import AppKit

@MainActor enum BuildIdentity {
    static var isLocal: Bool { _isDebugAssertConfiguration() }
    static var name: String { isLocal ? "WMac! L" : "WMac!" }
    static func icon(_ original: NSImage?) -> NSImage? {
        guard isLocal, let original else { return original }
        let image = NSImage(size: NSSize(width: 256, height: 256))
        image.lockFocus()
        original.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: NSRect(x: 164, y: 0, width: 92, height: 92)).fill()
        ("L" as NSString).draw(at: NSPoint(x: 191, y: 9), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.white
        ])
        image.unlockFocus()
        return image
    }
}

@MainActor final class AboutWindowController: NSWindowController, NSWindowDelegate {
    init() {
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:500,height:550),
            styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = tr("About WMac!","О WMac!")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window:window)
        window.delegate = self

        let background = NSVisualEffectView(frame:window.contentView?.bounds ?? .zero)
        background.material = .underWindowBackground
        background.blendingMode = .withinWindow
        background.state = .active
        background.autoresizingMask = [.width,.height]
        window.contentView = background

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        let artwork = NSImageView()
        artwork.imageScaling = .scaleProportionallyUpOrDown
        // Load our bundled artwork directly: applicationIconImage can be unset or cached.
        let icon = Bundle.main.url(forResource:"AppIcon",withExtension:"icns")
            .flatMap { NSImage(contentsOf:$0) }
        artwork.image = BuildIdentity.icon(icon ?? NSApp.applicationIconImage)
        artwork.setAccessibilityLabel(tr("An apple caught in a windowpane","Яблоко застряло в оконном стекле"))
        artwork.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            artwork.widthAnchor.constraint(equalToConstant:146),
            artwork.heightAnchor.constraint(equalToConstant:146)
        ])
        stack.addArrangedSubview(artwork)
        stack.setCustomSpacing(5,after:artwork)
        stack.addArrangedSubview(label(BuildIdentity.name,size:32,weight:.bold))

        let subtitle = label(tr("Your taskbar for macOS","Ваша панель задач для macOS"),size:15,weight:.medium)
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(subtitle)
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "—"
        let number = label(tr("Version \(version) (\(build))","Версия \(version) (\(build))"),size:12,weight:.regular)
        number.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(number)
        let channel = label(BuildIdentity.isLocal
            ? tr("L · Local Debug build", "L · Локальная Debug-сборка")
            : tr("Release build", "Релизная сборка"), size:12, weight:.medium)
        stack.addArrangedSubview(channel)
        let location = label(Bundle.main.bundleURL.path, size:11, weight:.regular)
        location.isSelectable = true
        location.maximumNumberOfLines = 3
        location.preferredMaxLayoutWidth = 400
        location.textColor = .secondaryLabelColor
        stack.addArrangedSubview(location)
        stack.setCustomSpacing(15,after:location)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant:360).isActive = true
        stack.addArrangedSubview(separator)
        stack.setCustomSpacing(16,after:separator)

        let description = label(tr(
            "A native macOS taskbar for switching between running apps, their windows, and pinned shortcuts.",
            "Нативная панель задач macOS для переключения между приложениями, их окнами и закреплёнными ярлыками."),
            size:13,weight:.regular)
        description.maximumNumberOfLines = 3
        description.preferredMaxLayoutWidth = 360
        description.textColor = .secondaryLabelColor
        stack.addArrangedSubview(description)
        stack.setCustomSpacing(19,after:description)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 12
        let github = NSButton(title:tr("View on GitHub","Открыть GitHub"),target:self,action:#selector(openGitHub))
        github.bezelStyle = .rounded
        github.controlSize = .large
        let close = NSButton(title:tr("Close","Закрыть"),target:self,action:#selector(closeAbout))
        close.bezelStyle = .rounded
        close.controlSize = .large
        close.keyEquivalent = "\r"
        buttons.addArrangedSubview(github)
        buttons.addArrangedSubview(close)
        stack.addArrangedSubview(buttons)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo:background.centerXAnchor),
            stack.topAnchor.constraint(equalTo:background.topAnchor,constant:30),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo:background.leadingAnchor,constant:32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo:background.trailingAnchor,constant:-32),
            stack.bottomAnchor.constraint(lessThanOrEqualTo:background.bottomAnchor,constant:-25)
        ])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) unavailable") }

    private func label(_ value:String,size:CGFloat,weight:NSFont.Weight) -> NSTextField {
        let text = NSTextField(wrappingLabelWithString:value)
        text.font = .systemFont(ofSize:size,weight:weight)
        text.alignment = .center
        text.isSelectable = false
        return text
    }
    func show() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification:Notification) {
        if !NSApp.windows.contains(where:{$0 !== window && $0.isVisible && $0.canBecomeKey}) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
    @objc private func closeAbout() { window?.performClose(nil) }
    @objc private func openGitHub() {
        guard let url = URL(string:"https://github.com/DimonSmart/WMac") else { return }
        NSWorkspace.shared.open(url)
    }
}
