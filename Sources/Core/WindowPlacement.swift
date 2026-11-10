import AppKit
import ApplicationServices

/// The macOS Accessibility coordinate system has a top-left origin. Store only
/// monitor-relative geometry; display IDs are ephemeral across reconnects.
struct WindowPlacementDisplay: Equatable, Sendable {
    let uuid: UUID
    let frame: CGRect
    let visible: CGRect

    @MainActor static func connected(workArea: (NSScreen) -> CGRect) -> [Self] {
        let screens = NSScreen.screens
        guard let primary = screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }) else { return [] }
        let top = primary.frame.maxY
        func ax(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        }
        return screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let displayUUID = CGDisplayCreateUUIDFromDisplayID(id),
                  let uuid = UUID(uuidString: CFUUIDCreateString(nil, displayUUID.takeRetainedValue()) as String) else { return nil }
            return Self(uuid: uuid, frame: ax(screen.frame), visible: ax(workArea(screen)))
        }
    }
}

enum WindowPlacementGeometry {
    static func focusedNormalWindow(_ windows: [WindowReference]) -> WindowReference? {
        let focused = windows.filter { $0.isFocused && isNormalWindow($0) }
        return focused.count == 1 ? focused[0] : nil
    }

    static func restorableNormalWindow(_ windows: [WindowReference],
                                       focusedWindowStatus: AXFocusedWindowStatus) -> WindowReference? {
        let focused = windows.filter { $0.isFocused && isNormalWindow($0) }
        if focused.count == 1 { return focused[0] }
        guard focused.isEmpty,
              !windows.contains(where: { $0.isFocused }),
              focusedWindowStatus == .notReported else { return nil }
        let normal = windows.filter(isNormalWindow)
        return normal.count == 1 ? normal[0] : nil
    }

    private static func isNormalWindow(_ window: WindowReference) -> Bool {
        !window.isMinimized && window.frame != nil &&
        window.role == kAXWindowRole as String &&
        (window.subrole == nil || window.subrole == kAXStandardWindowSubrole as String)
    }

    static func display(for uuid: UUID, in displays: [WindowPlacementDisplay]) -> WindowPlacementDisplay? {
        let matches = displays.filter { $0.uuid == uuid }
        return matches.count == 1 ? matches[0] : nil
    }

    static func capture(_ frame: CGRect, displays: [WindowPlacementDisplay]) -> SavedWindowPlacement? {
        guard valid(frame) else { return nil }
        let areas = displays.map { display -> (WindowPlacementDisplay, CGFloat) in
            let intersection = display.frame.intersection(frame)
            return (display, intersection.isNull ? 0 : intersection.width * intersection.height)
        }.sorted { $0.1 > $1.1 }
        guard let selected = areas.first, selected.1 > 0,
              areas.count == 1 || selected.1 > areas[1].1,
              display(for: selected.0.uuid, in: displays) != nil else { return nil }
        return SavedWindowPlacement(
            displayUUID: selected.0.uuid,
            x: Double(frame.minX - selected.0.frame.minX),
            y: Double(frame.minY - selected.0.frame.minY),
            width: Double(frame.width), height: Double(frame.height)
        )
    }

    static func restored(_ placement: SavedWindowPlacement, on display: WindowPlacementDisplay) -> CGRect? {
        guard placement.isValid, valid(display.frame), valid(display.visible),
              display.uuid == placement.displayUUID else { return nil }
        let work = display.visible.intersection(display.frame)
        guard valid(work) else { return nil }
        let width = min(CGFloat(placement.width), work.width)
        let height = min(CGFloat(placement.height), work.height)
        let x = min(max(display.frame.minX + CGFloat(placement.x), work.minX), work.maxX - width)
        let y = min(max(display.frame.minY + CGFloat(placement.y), work.minY), work.maxY - height)
        let target = CGRect(x: x, y: y, width: width, height: height)
        return valid(target) ? target : nil
    }

    static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 &&
        abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite &&
        rect.width.isFinite && rect.height.isFinite &&
        rect.width > 0 && rect.height > 0
    }
}

/// One bounded attempt, only after LaunchService confirmed a new instance.
/// The injected boundaries also let tests verify that missing screens, stale
/// process lifetimes and user edits never result in an AX write.
@MainActor
final class WindowPlacementService {
    private let displays: () -> [WindowPlacementDisplay]
    private let trusted: () -> Bool
    private let live: (InstanceID) -> Bool
    private let windows: (InstanceID) async -> WindowResult
    private let arrange: (InstanceID, UUID, CGRect, CGRect) async -> Bool

    init(displays: @escaping () -> [WindowPlacementDisplay],
         trusted: @escaping () -> Bool,
         live: @escaping (InstanceID) -> Bool,
         windows: @escaping (InstanceID) async -> WindowResult,
         arrange: @escaping (InstanceID, UUID, CGRect, CGRect) async -> Bool) {
        self.displays = displays
        self.trusted = trusted
        self.live = live
        self.windows = windows
        self.arrange = arrange
    }

    func capture(for instance: InstanceID) async -> SavedWindowPlacement? {
        guard trusted(), live(instance),
              case .windows(let candidates, let diagnostics) = await windows(instance),
              diagnostics.status == .complete,
              live(instance),
              let focused = WindowPlacementGeometry.focusedNormalWindow(candidates),
              let frame = focused.frame else { return nil }
        return WindowPlacementGeometry.capture(frame, displays: displays())
    }

    @discardableResult
    func restore(_ placement: SavedWindowPlacement, for instance: InstanceID,
                 deadline: Date, stillApplicable: () -> Bool = { true }) async -> Bool {
        guard placement.isValid, trusted(), live(instance), stillApplicable(),
              WindowPlacementGeometry.display(for: placement.displayUUID, in: displays()) != nil else { return false }
        var first: WindowReference?
        while !Task.isCancelled && Date() < deadline {
            guard trusted(), live(instance), stillApplicable(),
                  WindowPlacementGeometry.display(for: placement.displayUUID, in: displays()) != nil else { return false }
            if case .windows(let candidates, let diagnostics) = await windows(instance),
               diagnostics.status == .complete,
               let candidate = WindowPlacementGeometry.restorableNormalWindow(
                   candidates, focusedWindowStatus: diagnostics.focusedWindowStatus),
               let current = candidate.frame {
                if let first {
                    // Any change to window identity or geometry during settling
                    // is treated as user/application ownership; never override it.
                    guard first.identity == candidate.identity,
                          let original = first.frame,
                          WindowPlacementGeometry.sameFrame(original, current),
                          Date() < deadline,
                          let display = WindowPlacementGeometry.display(for: placement.displayUUID, in: displays()),
                          let target = WindowPlacementGeometry.restored(placement, on: display),
                          live(instance), stillApplicable() else { return false }
                    if WindowPlacementGeometry.sameFrame(current, target) { return true }
                    return await arrange(instance, candidate.id, current, target)
                }
                first = candidate
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            if first != nil { return false }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }
}
