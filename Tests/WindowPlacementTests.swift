import AppKit
import ApplicationServices

@MainActor func testWindowPlacement(_ check: (Bool, String) -> Void) async throws {
    let primaryID = UUID(), externalID = UUID()
    let primary = WindowPlacementDisplay(
        uuid: primaryID, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visible: CGRect(x: 0, y: 24, width: 1440, height: 840))
    let external = WindowPlacementDisplay(
        uuid: externalID, frame: CGRect(x: -1920, y: -120, width: 1920, height: 1080),
        visible: CGRect(x: -1920, y: -90, width: 1920, height: 1000))
    let current = CGRect(x: -1580, y: 40, width: 880, height: 620)
    guard let saved = WindowPlacementGeometry.capture(current, displays: [primary, external]) else {
        check(false, "external monitor window is capturable")
        return
    }
    check(saved.displayUUID == externalID && saved.x == 340 && saved.y == 160 &&
          saved.width == 880 && saved.height == 620,
          "window position is stored relative to the full external display, not the main display")
    let reconnected = WindowPlacementDisplay(
        uuid: externalID, frame: CGRect(x: 1440, y: -300, width: 1920, height: 1080),
        visible: CGRect(x: 1440, y: -280, width: 1920, height: 1000))
    check(WindowPlacementGeometry.restored(saved, on: reconnected) ==
          CGRect(x: 1780, y: -140, width: 880, height: 620),
          "screen relocation changes global AX coordinates without changing saved relative placement")
    let undersized = WindowPlacementDisplay(
        uuid: externalID, frame: CGRect(x: 1440, y: 0, width: 600, height: 400),
        visible: CGRect(x: 1460, y: 30, width: 550, height: 340))
    check(WindowPlacementGeometry.restored(saved, on: undersized) ==
          CGRect(x: 1460, y: 30, width: 550, height: 340),
          "saved window is clipped into the visible work area on a smaller display")
    check(WindowPlacementGeometry.restored(saved, on: primary) == nil &&
          WindowPlacementGeometry.display(for: externalID, in: [primary]) == nil &&
          WindowPlacementGeometry.display(for: externalID, in: [external, external]) == nil,
          "missing, mismatched or ambiguous monitors have no fallback target")
    check(WindowPlacementGeometry.capture(current, displays: [external, external]) == nil,
          "ambiguous monitor UUID cannot be remembered")
    let encoded = try JSONEncoder().encode(saved)
    check(try JSONDecoder().decode(SavedWindowPlacement.self, from: encoded) == saved,
          "saved display UUID and Double geometry round-trip without a process/window identifier")
    let invalid = SavedWindowPlacement(displayUUID: externalID, x: 0, y: 0, width: -10, height: 20)
    check(!invalid.isValid && WindowPlacementGeometry.restored(invalid, on: external) == nil,
          "invalid dimensions never reach Accessibility")

    let instance = InstanceID(pid: 301, startDate: Date(timeIntervalSince1970: 1234))
    let window = WindowReference(
        id: UUID(), instance: instance, title: "Document", isMinimized: false, isFocused: true,
        canMinimize: true, frame: current, lifecycle: 5, role: kAXWindowRole as String,
        subrole: kAXStandardWindowSubrole as String)
    var inactive = window
    inactive.isFocused = false
    check(WindowPlacementGeometry.focusedNormalWindow([window, inactive])?.id == window.id,
          "one focused standard window wins even when the process owns several windows")
    var otherFocused = window
    otherFocused.id = UUID()
    check(WindowPlacementGeometry.focusedNormalWindow([window, otherFocused]) == nil,
          "two focused standard windows are ambiguous and cannot be saved")
    var dialog = window
    dialog.subrole = "AXDialog"
    check(WindowPlacementGeometry.focusedNormalWindow([dialog]) == nil,
          "dialogs and nonstandard windows are not remembered")

    let diagnostics = AXEnumerationDiagnostics(
        status: .complete, listedElements: 1, inspectedElements: 1,
        confirmedElements: 1, skippedElements: 0, issues: [],
        failureReason: nil, failedAttribute: nil, axError: nil)
    var reads = 0
    var writes = 0
    var lastTarget: CGRect?
    let service = WindowPlacementService(
        displays: { [primary, external] }, trusted: { true },
        live: { $0 == instance },
        windows: { id in
            reads += 1
            check(id == instance, "window enumeration stays within the confirmed process lifetime")
            return .windows([window], diagnostics)
        },
        arrange: { id, windowID, expected, target in
            writes += 1
            check(id == instance && windowID == window.id && expected == current,
                  "conditional AX mutation targets the same window and its observed frame")
            lastTarget = target
            return true
        })
    check(await service.capture(for: instance) == saved,
          "remember uses the unique focused window and stable monitor UUID")
    check(await service.restore(saved, for: instance, deadline: Date().addingTimeInterval(2)) &&
          writes == 1 && lastTarget == current,
          "one confirmed process has at most one conditional restore attempt")
    // Same-frame restoration is a no-op, not an additional window mutation.
    check(await service.restore(saved, for: instance, deadline: Date().addingTimeInterval(2)) && writes == 1,
          "already positioned window requires no AX write")
    check(reads >= 4, "successful restore re-reads a stable frame before writing")

    var attempts = 0
    let disappeared = WindowPlacementService(
        displays: { [primary] }, trusted: { true }, live: { _ in true },
        windows: { _ in attempts += 1; return .windows([window], diagnostics) },
        arrange: { _, _, _, _ in attempts += 1; return true })
    check(!(await disappeared.restore(saved, for: instance, deadline: Date().addingTimeInterval(2))) &&
          attempts == 0, "disconnected external monitor completely bypasses window enumeration and changes")

    let noPermission = WindowPlacementService(
        displays: { [external] }, trusted: { false }, live: { _ in true },
        windows: { _ in attempts += 1; return .windows([window], diagnostics) },
        arrange: { _, _, _, _ in attempts += 1; return true })
    check(await noPermission.capture(for: instance) == nil &&
          !(await noPermission.restore(saved, for: instance, deadline: Date().addingTimeInterval(2))) &&
          attempts == 0, "missing Accessibility permission never triggers a permission prompt or AX write")

    var samples = 0
    var shifted = window
    shifted.frame = current.offsetBy(dx: 90, dy: 0)
    let changed = WindowPlacementService(
        displays: { [external] }, trusted: { true }, live: { _ in true },
        windows: { _ in
            samples += 1
            return .windows(samples == 1 ? [window] : [shifted], diagnostics)
        },
        arrange: { _, _, _, _ in writes += 1; return true })
    check(!(await changed.restore(saved, for: instance, deadline: Date().addingTimeInterval(2))) &&
          samples == 2 && writes == 1,
          "user or application movement during settling cancels restoration")
    check(!(await service.restore(saved, for: instance, deadline: .distantPast)) && writes == 1,
          "expired five-second launch budget cannot write a window")

    let cancelled = WindowPlacementService(
        displays: { [external] }, trusted: { true }, live: { _ in true },
        windows: { _ in .windows([window], diagnostics) },
        arrange: { _, _, _, _ in writes += 1; return true })
    check(!(await cancelled.restore(saved, for: instance, deadline: Date().addingTimeInterval(2),
                                    stillApplicable: { false })) && writes == 1,
          "forgetting or relinking the pin during launch cancels pending restoration")
}
