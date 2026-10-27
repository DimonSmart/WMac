import AppKit
@preconcurrency import ApplicationServices

var failures = 0
@MainActor func check(_ condition: Bool, _ message: String) {
    print("\(condition ? "PASS" : "FAIL") UNIT \(message)")
    if !condition { failures += 1 }
}
let original = InstanceID(pid: 123, launchDate: Date(timeIntervalSince1970: 100))
let reused = InstanceID(pid: 123, launchDate: Date(timeIntervalSince1970: 200))
check(Set([original, original, reused]).count == 2, "PID reuse produces a different lifetime identity")
let a = AppDefinition(url: URL(fileURLWithPath: "/Applications/A.app"), bundleID: "test.app")
let b = AppDefinition(url: URL(fileURLWithPath: "/Applications/B.app"), bundleID: "test.app")
check(a != b, "same bundle identifier at different paths remains distinct")
let normalized = AppDefinition(url: URL(fileURLWithPath: "/Applications/folder/../A.app"), bundleID: "test.app")
check(a == normalized, "application URL is canonicalized")
let monitor = ProcessMonitor()
check(monitor.running(original) == nil, "nonexistent or recycled process is not actionable")
monitor.stop()

func fixture(_ pid: pid_t, _ time: Double, _ definition: AppDefinition? = a, name: String = "A") -> Instance {
    Instance(id: InstanceID(pid: pid, launchDate: Date(timeIntervalSince1970: time)), name: name,
             url: definition?.url, bundleID: definition?.bundleID ?? "")
}
func resolved(_ definition: AppDefinition, id: UUID = UUID()) -> ResolvedPin {
    ResolvedPin(pin: Pin(id: id, application: definition, name: "Pinned"), availability: .available, recoveryNote: nil)
}
let state = TaskbarCoordinator()
let one = fixture(11, 1), two = fixture(12, 2), three = fixture(13, 3)
let elsewhere = fixture(14, 4, b)
let incomplete = fixture(15, 5, nil)
@MainActor func represented(_ state: TaskbarCoordinator) -> [InstanceID] { state.snapshot.buttons.compactMap { $0.instance?.id } }
state.apply([three, one, two, elsewhere, incomplete, one], active: two.id)
check(represented(state) == [one.id, two.id, three.id, elsewhere.id, incomplete.id], "initial snapshot sorts lifetimes, deduplicates and preserves incomplete metadata")
let initialIDs = state.snapshot.buttons.map(\.id)
state.apply([incomplete, elsewhere, two, one, three], active: three.id)
check(state.snapshot.buttons.map(\.id) == initialIDs, "repeated reordered snapshots and focus changes preserve temporary order")
let pinned = resolved(a)
check(state.add(pinned) && !state.add(resolved(a)), "adding a pin rejects duplicate application identity")
check(state.snapshot.buttons.first?.instance?.id == three.id && represented(state).count == 5, "pin takes active matching third process with exactly one button per lifetime")
state.apply([one, two, three, elsewhere, incomplete], active: one.id)
check(state.snapshot.buttons.first?.instance?.id == three.id && state.snapshot.buttons.filter(\.isActive).map { $0.instance?.id } == [one.id], "focus highlights exact process without reassigning pin")
check(state.snapshot.buttons.first?.ordinal == 3 && state.snapshot.buttons.first?.tooltip.contains("3") == true, "instance tooltips have distinct ordinal")
state.apply([one, two, elsewhere], active: two.id)
check(state.snapshot.buttons.first?.instance?.id == one.id && Set(represented(state)).count == 3, "assigned process termination transfers to earliest survivor regardless of focus")
state.apply([two, elsewhere], active: three.id)
check(state.snapshot.buttons.first?.instance?.id == two.id && state.snapshot.activeInstance == nil, "successive termination transfers pin and clears vanished active lifetime")
state.apply([elsewhere], active: nil)
check(state.snapshot.buttons.first?.instance == nil && state.snapshot.buttons.count == 2, "idle pin remains and other path with same bundle ID stays separate")
let reusedOne = fixture(11, 99)
state.apply([reusedOne], active: one.id)
check(represented(state) == [reusedOne.id] && state.instance(for: .instance(one.id)) == nil && state.snapshot.activeInstance == nil, "PID reuse removes stale button action and highlight")
state.setExclusions([a]); check(represented(state).isEmpty, "exclusion seam filters eligible instances")
state.setExclusions([]); check(represented(state) == [reusedOne.id], "removing exclusion restores current raw snapshot")
let secondPin = resolved(b)
_ = state.add(secondPin); state.move(secondPin.pin.id, to: 0)
check(state.pins.map { $0.pin.id } == [secondPin.pin.id, pinned.pin.id], "pin order can be changed")
check(!state.relink(secondPin.pin.id, to: resolved(a)), "relink rejects duplicate identity")
let c = AppDefinition(url: URL(fileURLWithPath: "/Applications/C.app"), bundleID: "test.c")
check(state.relink(secondPin.pin.id, to: resolved(c)) && state.pins.first?.pin.id == secondPin.pin.id, "relink retains stable pin identity")
state.remove(pinned.pin.id)
check(state.snapshot.buttons.contains { $0.id == .instance(reusedOne.id) }, "unpin returns live instance to temporary order")

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wmac-model-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let idleState = TaskbarCoordinator()
_ = idleState.add(resolved(a))
idleState.apply([three, one, two], active: three.id)
check(idleState.snapshot.buttons.first?.instance?.id == one.id, "existing idle pin acquires earliest arrival even if later process is active")
let storeURL = directory.appendingPathComponent("pins.json")
var io = PinStorageIO()
io.bundleID = { url in url.path == a.url.path || url.path == b.url.path ? "test.app" : nil }
io.bookmark = { Data($0.path.utf8) }
io.resolve = { data in BookmarkResolution(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false) }
let store = PinStore(url: storeURL, io: io)
check(try await store.load().pins.isEmpty, "missing persistence file starts empty")
let savedPins = [secondPin.pin, pinned.pin]
try await store.save(savedPins)
let restart = try await PinStore(url: storeURL, io: io).load()
check(restart.pins.map(\.pin) == savedPins, "restart preserves pin identity and reorder without transient process state")
let savedData = try Data(contentsOf: storeURL)
let json = String(decoding: savedData, as: UTF8.self)
check(!json.contains("pid") && !json.contains("launchDate") && !json.contains("window"), "saved schema contains no process/window identities")
var failingIO = io
failingIO.write = { _, _ in throw CocoaError(.fileWriteNoPermission) }
do { try await PinStore(url: storeURL, io: failingIO).save([]); check(false, "atomic write failure is surfaced") }
catch { check(try Data(contentsOf: storeURL) == savedData, "failed atomic persistence preserves prior committed bytes") }
let legacy = """
{"version":1,"pins":[{"path":"/Applications/B.app","bundleID":"test.app","name":"B"},{"path":"/Applications/A.app","bundleID":"test.app","name":"A"}]}
"""
try Data(legacy.utf8).write(to: storeURL)
let migrated = try await store.load()
check(migrated.migrated && migrated.pins.map { $0.pin.application } == [b, a], "version 1 migration preserves application order")
let migratedAgain = try await store.load()
check(!migratedAgain.migrated && migratedAgain.pins.map(\.pin) == migrated.pins.map(\.pin), "migration commits stable UUIDs and is idempotent")
try Data(legacy.utf8).write(to: storeURL)
do { _ = try await PinStore(url: storeURL, io: failingIO).load(); check(false, "failed migration surfaced") }
catch { check(try Data(contentsOf: storeURL) == Data(legacy.utf8), "failed migration preserves original schema for recovery") }
for invalid in ["broken", "{\"version\":99,\"pins\":[]}", "{\"version\":2,\"pins\":[{}]}"] {
    try Data(invalid.utf8).write(to: storeURL)
    do { _ = try await store.load(); check(false, "bad state must be rejected") }
    catch { check(try Data(contentsOf: storeURL) == Data(invalid.utf8), "corrupt or unsupported state remains intact for explicit recovery") }
}
var recoveryIO = io
recoveryIO.resolve = { _ in BookmarkResolution(url: b.url, stale: true) }
let bookmarked = Pin(application: a, name: "Moved", bookmark: Data([1]))
try await store.save([bookmarked])
let recovered = try await PinStore(url: storeURL, io: recoveryIO).load()
check(recovered.pins.first?.pin.application == b && recovered.pins.first?.recoveryNote != nil && recovered.pins.first?.pin.bookmark == Data(b.url.path.utf8), "stale moved bookmark recovers exact identity and refreshes data")
var invalidBookmarkIO = io
invalidBookmarkIO.resolve = { _ in throw CocoaError(.fileReadCorruptFile) }
let missingPin = Pin(application: c, name: "Missing", bookmark: Data([0]))
try await store.save([missingPin])
let missing = try await PinStore(url: storeURL, io: invalidBookmarkIO).load()
check(missing.pins.first?.availability == .missing && missing.pins.first?.pin.id == missingPin.id && missing.pins.first?.recoveryNote != nil, "invalid bookmark retains recoverable missing application pin")
let missingState = TaskbarCoordinator(); missingState.restore(missing.pins)
check(missingState.snapshot.buttons.first?.availability == .missing, "missing application state reaches immutable button snapshot")
try await store.save([bookmarked])
let fallback = try await PinStore(url: storeURL, io: invalidBookmarkIO).load()
check(fallback.pins.first?.availability == .available && fallback.pins.first?.pin.application == a, "invalid bookmark falls back safely to valid original path")
let distinctPins = TaskbarCoordinator()
_ = distinctPins.add(resolved(a)); _ = distinctPins.add(resolved(b))
distinctPins.apply([one, elsewhere], active: nil)
check(represented(distinctPins) == [one.id, elsewhere.id] && distinctPins.snapshot.buttons.count == 2, "pins at different paths never merge despite equal bundle identifiers")
let duplicatePin = resolved(a).pin
try await store.save([duplicatePin, duplicatePin])
do { _ = try await store.load(); check(false, "duplicate persistent pin must be rejected") }
catch { check(true, "duplicate persistent identities are rejected safely") }
var mismatchIO = recoveryIO
mismatchIO.bundleID = { url in url == a.url ? "test.app" : "different.app" }
try await store.save([bookmarked])
let mismatch = try await PinStore(url: storeURL, io: mismatchIO).load()
check(mismatch.pins.first?.pin.application == a && mismatch.pins.first?.availability == .available, "bookmark pointing to different bundle identity cannot hijack pin")
// Controlled AX boundary. No remote AX call or permission mutation occurs here.
final class ControlledAX: @unchecked Sendable {
    let lock = NSLock()
    let first = AXUIElementCreateApplication(900001)
    let second = AXUIElementCreateApplication(900002)
    var allowed = true
    var alive = true
    var activation = true
    var values: [AXWindowValue] = []
    var actions: [WindowAction] = []
    var actionError: String?
    var readError: String?
    var reads = 0
    var activationRequests = 0
    var allCallsOffMain = true
    func edit(_ body: (ControlledAX) -> Void) { lock.lock(); defer { lock.unlock() }; body(self) }
    func boundary() -> AccessibilityBoundary {
        var boundary = AccessibilityBoundary()
        boundary.observesWindows = false
        boundary.trusted = { self.lock.withLock { self.allowed } }
        boundary.live = { _ in self.lock.withLock { self.alive } }
        boundary.read = { _ in self.lock.withLock {
            self.reads += 1; self.allCallsOffMain = self.allCallsOffMain && !Thread.isMainThread
            if let error = self.readError { return .failure(AXFailure(message: error)) }
            return .success(self.values)
        } }
        boundary.perform = { _, element, action in self.lock.withLock {
            self.allCallsOffMain = self.allCallsOffMain && !Thread.isMainThread
            self.actions.append(action)
            if let error = self.actionError { return error }
            self.values = self.values.map { value in
                let target = CFEqual(value.element, element)
                return AXWindowValue(element: value.element, title: value.title,
                                     minimized: target ? action == .minimize : value.minimized,
                                     focused: target && action == .restore, canMinimize: value.canMinimize)
            }
            return nil
        } }
        boundary.activate = { _ in self.lock.withLock { self.activationRequests += 1; return self.alive && self.activation } }
        return boundary
    }
}
let controlled = ControlledAX()
controlled.edit { value in
    value.values = [AXWindowValue(element: value.first, title: "Same title", minimized: false, focused: false, canMinimize: true),
                    AXWindowValue(element: value.second, title: "Same title", minimized: false, focused: true, canMinimize: true)]
}
let windowService = AccessibilityService(boundary: controlled.boundary())
let windowInstance = fixture(900001, 1).id
if case .windows(let initial) = await windowService.windows(for: windowInstance) {
    check(initial.count == 2 && initial[0].id != initial[1].id, "equal titles retain distinct actual AX identities")
    if case .windows(let repeated) = await windowService.windows(for: windowInstance) {
        check(initial.map(\.id) == repeated.map(\.id), "reconciliation preserves window UUIDs by AX equality")
    }
    controlled.edit { $0.readError = "Controlled timeout" }
    let timedOut = await windowService.switchTo(windowInstance)
    check(timedOut.outcome == .activatedOnly && timedOut.message.contains("Controlled timeout"), "transient read failure reports process fallback with its reason")
    controlled.edit { $0.readError = nil }
    if case .windows(let recovered) = await windowService.windows(for: windowInstance) {
        check(recovered.map(\.id) == initial.map(\.id), "transient unreadability does not fabricate closure or change known AX identities")
    } else { check(false, "controlled timeout recovery") }
    let minimizeResult = await windowService.switchTo(windowInstance, minimizeIfActive: true, isActive: true)
    check(minimizeResult.outcome == .minimized, "toggle minimizes focused window")
    let toggleRestore = await windowService.switchTo(windowInstance, minimizeIfActive: true, isActive: true)
    check(toggleRestore.outcome == .restored && controlled.lock.withLock { controlled.values[1].focused && !controlled.values[1].minimized }, "next toggle restores the same AX identity")
    _ = await windowService.select(initial[0])
    let lastActive = await windowService.switchTo(windowInstance)
    check(lastActive.outcome == .restored && controlled.lock.withLock { controlled.values[0].focused }, "selection updates ordinary-switch last-active choice")
    controlled.edit { $0.values.removeFirst() }
    let vanished = await windowService.select(initial[0])
    check(vanished.outcome == .activatedOnly && vanished.activationAccepted, "vanished selected window falls back to exact process without choosing another window")
    controlled.edit { $0.actionError = "Controlled AX action failure" }
    let failed = await windowService.switchTo(windowInstance)
    check(failed.outcome == .activatedOnly && failed.message.contains("Controlled AX action failure"), "AX failures are explanatory process fallbacks rather than success")
    controlled.edit { $0.actionError = nil; $0.values = [AXWindowValue(element: $0.second, title: "Renamed", minimized: false, focused: true, canMinimize: false)] }
    let unmanageable = await windowService.switchTo(windowInstance, minimizeIfActive: true, isActive: true)
    check(unmanageable.outcome == .activatedOnly, "unmanageable focused window does not minimize entire application")
    controlled.edit { $0.allowed = false }
    let beforeReads = controlled.lock.withLock { controlled.reads }
    let noAccess = await windowService.switchTo(windowInstance)
    check(noAccess.outcome == .activatedOnly && noAccess.activationAccepted && controlled.lock.withLock { controlled.reads == beforeReads }, "controlled unavailable permission skips AX and retains process activation")
    controlled.edit { $0.allowed = true; $0.alive = false }
    let terminated = await windowService.select(initial[1])
    check(terminated.outcome == .unavailable && !terminated.activationAccepted, "terminated lifetime rejects both AX and process actions")
    controlled.edit { $0.alive = true; $0.activation = false }
    let rejected = await windowService.switchTo(windowInstance)
    check(rejected.outcome == .unavailable && !rejected.activationAccepted, "activation rejection is observable even after AX action")
    check(controlled.lock.withLock { controlled.allCallsOffMain }, "all controlled enumeration/action calls execute off the main thread")
} else { check(false, "controlled window snapshot must be available") }
check(AccessibilityPermissionStatus(trusted: false).explanation.contains("Process switching"), "permission presentation explains retained process features")
try await testApplicationCatalog(check)
try await testPinMutations(check)
try await testSettings(check)
try testSystemDockRecovery(check)
let primaryLayout = DisplayLayout(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
let leftLayout = DisplayLayout(id: 2, frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080))
check(primaryLayout.panelFrame == CGRect(x: 8, y: 8, width: 1424, height: 52), "default panel geometry is 52pt with screen-relative insets")
check(leftLayout.panelFrame.minX == -1912 && leftLayout.panelFrame.minY == -192, "secondary display geometry preserves negative origins")
let delta = DisplayLayout.reconcile(owned: [1, 3], screens: [primaryLayout, leftLayout])
check(delta.added == [2] && delta.removed == [3], "display reconciliation adds connected panels and removes disconnected ownership")
let captureState = TaskbarCoordinator()
captureState.apply([one, two], active: one.id)
let capture = ButtonCapture(captureState.snapshot.buttons[0])
check(capture.matches(captureState.snapshot), "input capture matches exact current instance")
captureState.apply([Instance(id: InstanceID(pid: one.id.pid, launchDate: Date(timeIntervalSince1970: 999)), name: one.name, url: one.url, bundleID: one.bundleID), two], active: nil)
check(!capture.matches(captureState.snapshot), "stale captured button cannot target a reused PID")
let capturePin = resolved(a)
captureState.apply([one, two], active: nil); captureState.restore([capturePin])
let pinCapture = ButtonCapture(captureState.snapshot.buttons[0])
captureState.apply([two], active: nil)
check(!pinCapture.matches(captureState.snapshot), "stale pin menu cannot retarget a newly assigned surviving process")
check(PanelPreferences().middleClickNewInstance, "controller preferences default middle-click on")
for width: CGFloat in [480, 1440, 1920] {
    let regions = PanelRegions(width: width, contentWidth: 4000)
    check(regions.overflow && regions.apps.width >= 36 && regions.previous.width == 36 && regions.next.height == 36 && regions.controls.width == 36, "overflow retains minimum input targets at width \(width)")
    check(regions.launcher.maxX <= regions.previous.minX && regions.next.maxX <= regions.clock.minX && regions.clock.maxX <= regions.controls.minX && regions.controls.maxX <= width, "overflow never covers persistent clock or controls at width \(width)")
}
check(!PanelRegions(width: 1440, contentWidth: 88).overflow, "short process lists are centered without overflow controls")
print("UNIT RESULT failures=\(failures)")
exit(failures == 0 ? 0 : 1)
