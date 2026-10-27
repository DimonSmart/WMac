import Foundation

struct Pin: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let application: AppDefinition
    let name: String
    let bookmark: Data?
    init(id: UUID = UUID(), application: AppDefinition, name: String, bookmark: Data? = nil) {
        self.id = id; self.application = application; self.name = name; self.bookmark = bookmark
    }
}
enum PinAvailability: String, Sendable { case available, missing }
struct ResolvedPin: Equatable, Sendable {
    let pin: Pin
    let availability: PinAvailability
    let recoveryNote: String?
}
enum TaskbarButtonID: Hashable, Sendable { case pin(UUID), instance(InstanceID) }
struct TaskbarButton: Identifiable, Sendable {
    let id: TaskbarButtonID
    let pinID: UUID?
    let application: AppDefinition?
    let instance: Instance?
    let name: String
    let ordinal: Int?
    let isActive: Bool
    let availability: PinAvailability
    var tooltip: String { ordinal.map { "\(name) — instance \($0)" } ?? name }
}
struct TaskbarSnapshot: Sendable {
    let buttons: [TaskbarButton]
    let activeInstance: InstanceID?
}

/// Sole composer. The presentation layer never assigns a process to a pin.
@MainActor final class TaskbarCoordinator {
    private(set) var pins: [ResolvedPin] = []
    private var allInstances: [Instance] = []
    private var instances: [Instance] = []
    private var rawActive: InstanceID?
    private var active: InstanceID?
    private var order: [InstanceID] = []
    private var assignments: [UUID: InstanceID] = [:]
    private var excluded: Set<AppDefinition> = []
    private(set) var snapshot = TaskbarSnapshot(buttons: [], activeInstance: nil)
    var changed: ((TaskbarSnapshot) -> Void)?

    func restore(_ values: [ResolvedPin]) {
        var ids = Set<UUID>(); var applications = Set<AppDefinition>()
        pins = values.filter { ids.insert($0.pin.id).inserted && applications.insert($0.pin.application).inserted }
        compose()
    }
    func apply(_ values: [Instance], active: InstanceID?) {
        allInstances = values; rawActive = active
        var seen = Set<InstanceID>()
        instances = values.filter { seen.insert($0.id).inserted && !($0.definition.map { excluded.contains($0) } ?? false) }
        self.active = active.flatMap { id in instances.contains(where: { $0.id == id }) ? id : nil }
        let live = Set(instances.map(\.id))
        order.removeAll { !live.contains($0) }
        let known = Set(order)
        order += instances.filter { !known.contains($0.id) }.sorted(by: Self.earlier).map(\.id)
        compose()
    }
    func setExclusions(_ values: Set<AppDefinition>) { excluded = values; apply(allInstances, active: rawActive) }
    @discardableResult func add(_ pin: ResolvedPin) -> Bool {
        guard !pins.contains(where: { $0.pin.application == pin.pin.application || $0.pin.id == pin.pin.id }) else { return false }
        pins.append(pin); compose(preferActivePin: pin.pin.id); return true
    }
    func remove(_ id: UUID) { pins.removeAll { $0.pin.id == id }; compose() }
    func move(_ id: UUID, to index: Int) {
        guard let old = pins.firstIndex(where: { $0.pin.id == id }) else { return }
        let value = pins.remove(at: old); pins.insert(value, at: min(max(0, index), pins.count)); compose()
    }
    @discardableResult func relink(_ id: UUID, to replacement: ResolvedPin) -> Bool {
        guard let index = pins.firstIndex(where: { $0.pin.id == id }),
              !pins.contains(where: { $0.pin.id != id && $0.pin.application == replacement.pin.application }) else { return false }
        let pin = replacement.pin
        pins[index] = ResolvedPin(pin: Pin(id: id, application: pin.application, name: pin.name, bookmark: pin.bookmark),
                                  availability: replacement.availability, recoveryNote: replacement.recoveryNote)
        assignments[id] = nil; compose(); return true
    }
    /// Revalidate this identity with ProcessMonitor immediately before performing an action.
    func instance(for button: TaskbarButtonID) -> InstanceID? { snapshot.buttons.first { $0.id == button }?.instance?.id }
    private static func earlier(_ a: Instance, _ b: Instance) -> Bool {
        a.id.launchDate == b.id.launchDate ? a.id.pid < b.id.pid : a.id.launchDate < b.id.launchDate
    }
    private func compose(preferActivePin: UUID? = nil) {
        let byID = Dictionary(uniqueKeysWithValues: instances.map { ($0.id, $0) })
        let pinIDs = Set(pins.map { $0.pin.id })
        assignments = assignments.filter { pinIDs.contains($0.key) }
        var used = Set<InstanceID>()
        var buttons: [TaskbarButton] = []
        func ordinal(_ instance: Instance) -> Int {
            let matches = instances.filter { other in
                if let definition = instance.definition { return other.definition == definition }
                return other.id == instance.id
            }.sorted(by: Self.earlier)
            return (matches.firstIndex(where: { $0.id == instance.id }) ?? 0) + 1
        }
        for resolved in pins where !excluded.contains(resolved.pin.application) {
            let pin = resolved.pin
            let matches = instances.filter { $0.definition == pin.application }.sorted(by: Self.earlier)
            let previous = assignments[pin.id].flatMap { byID[$0] }.flatMap { $0.definition == pin.application ? $0 : nil }
            // Only an explicit new pin selects the active match. Existing idle pins and
            // terminated assignments always acquire the earliest available process.
            let preferred = preferActivePin == pin.id ? matches.first(where: { $0.id == active }) : nil
            let instance = previous ?? preferred ?? matches.first
            assignments[pin.id] = instance?.id
            if let instance { used.insert(instance.id) }
            buttons.append(TaskbarButton(id: .pin(pin.id), pinID: pin.id, application: pin.application,
                                         instance: instance, name: instance?.name ?? pin.name,
                                         ordinal: instance.map(ordinal), isActive: instance?.id == active && instance != nil,
                                         availability: resolved.availability))
        }
        for id in order where !used.contains(id) {
            guard let instance = byID[id] else { continue }
            buttons.append(TaskbarButton(id: .instance(id), pinID: nil, application: instance.definition,
                                         instance: instance, name: instance.name, ordinal: ordinal(instance),
                                         isActive: id == active, availability: .available))
        }
        snapshot = TaskbarSnapshot(buttons: buttons, activeInstance: active); changed?(snapshot)
    }
}
