import AppKit

enum PanelIconSource: Hashable, Sendable {
    case application(AppDefinition)
    case instance(InstanceID)

    init?(_ button: TaskbarButton) {
        if let application = button.application { self = .application(application) }
        else if let instance = button.instance { self = .instance(instance.id) }
        else { return nil }
    }
}

/// System icon lookup and bounded rasterization stay off the UI actor.
actor PanelIcons {
    @MainActor static let fallback = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        ?? NSImage(size: NSSize(width: 32, height: 32))

    func icon(_ source: PanelIconSource) -> Data? {
        let image: NSImage
        switch source {
        case .application(let definition):
            image = NSWorkspace.shared.icon(forFile: definition.url.path)
        case .instance(let id):
            guard let app = NSRunningApplication(processIdentifier: id.pid), !app.isTerminated,
                  ProcessLifetime.startDate(for: app) == id.startDate,
                  let icon = app.icon else { return nil }
            image = icon
        }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 96, height: 96))
        return bitmap.representation(using: .png, properties: [:])
    }
}

struct DisplayLayout: Equatable {
    let id: UInt32
    let frame: CGRect
    var panelFrame: CGRect { panelFrame(height: 52) }
    func panelFrame(height: Double) -> CGRect { CGRect(x: frame.minX + 8, y: frame.minY + 8, width: max(0, frame.width - 16), height: min(64, max(40, height.isFinite ? height : 52))) }
    static func selected(_ screens: [DisplayLayout], all: Bool, primary: UInt32) -> [DisplayLayout] { all ? screens : screens.filter { $0.id == primary } }
    static func reconcile(owned: Set<UInt32>, screens: [DisplayLayout]) -> (added: Set<UInt32>, removed: Set<UInt32>) {
        let current = Set(screens.map(\.id))
        return (current.subtracting(owned), owned.subtracting(current))
    }
}
struct ButtonCapture: Sendable {
    let button: TaskbarButtonID
    let instance: InstanceID?
    let application: AppDefinition?
    init(_ value: TaskbarButton) { button = value.id; instance = value.instance?.id; application = value.application }
    func matches(_ snapshot: TaskbarSnapshot) -> Bool {
        snapshot.buttons.contains { $0.id == button && $0.instance?.id == instance && $0.application == application }
    }
}
struct PanelPreferences {
    var middleClickNewInstance = true
}

struct PanelRegions {
    let launcher: CGRect
    let apps: CGRect
    let previous: CGRect
    let next: CGRect
    let clock: CGRect
    let controls: CGRect
    let overflow: Bool
    init(width: CGFloat, contentWidth: CGFloat, height: CGFloat = 52) {
        let y = (height - 36) / 2
        controls = CGRect(x: max(0, width - 44), y: y, width: 36, height: 36)
        clock = CGRect(x: max(0, width - 148), y: y, width: 100, height: 36)
        launcher = CGRect(x: 8, y: y, width: 36, height: 36)
        // Reserve launcher, both overflow arrows, clock and controls before centering.
        let left: CGFloat = 88
        let right = max(left + 36, clock.minX - 44)
        let available = max(36, right - left)
        overflow = contentWidth > available
        let actual = min(available, max(36, contentWidth))
        let x = left + (available - actual) / 2
        apps = CGRect(x: x, y: 2, width: actual, height: height - 4)
        previous = CGRect(x: x - 40, y: y, width: 36, height: 36)
        next = CGRect(x: x + actual + 4, y: y, width: 36, height: 36)
    }
}
