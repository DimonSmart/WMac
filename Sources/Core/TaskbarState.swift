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

/// Persistent positions never contain PIDs. An application may have several distinct
/// slots, allowing independent instances to occupy remembered positions.
enum TaskbarLayoutSlot: Codable, Hashable, Sendable {
    case pin(UUID)
    case application(AppDefinition, UUID)
}

/// A process without a usable application identity can move for this session, but
/// cannot be restored after WMac restarts.
enum TaskbarPlacement: Hashable, Sendable {
    case saved(TaskbarLayoutSlot)
    case temporary(InstanceID)

    var persistent: TaskbarLayoutSlot? {
        if case .saved(let value) = self { return value }
        return nil
    }
}

/// Sole composer. Panels only render its ordered snapshot and never assign a
/// process to a pin or choose a persistent slot.
@MainActor final class TaskbarCoordinator {
    private(set) var pins: [ResolvedPin] = []
    private var allInstances: [Instance] = []
    private var instances: [Instance] = []
    private var rawActive: InstanceID?
    private var active: InstanceID?
    private var order: [InstanceID] = []
    private var assignments: [UUID: InstanceID] = [:]
    private var placements: [TaskbarPlacement] = []
    private var processPlacements: [InstanceID: TaskbarPlacement] = [:]
    private var buttonPlacements: [TaskbarButtonID: TaskbarPlacement] = [:]
    private var excluded: Set<AppDefinition> = []
    private(set) var snapshot = TaskbarSnapshot(buttons: [], activeInstance: nil)
    var changed: ((TaskbarSnapshot) -> Void)?
    var discoveredLayout: (() -> Void)?

    var savedLayout: [TaskbarLayoutSlot] { placements.compactMap(\.persistent) }

    func restore(_ values: [ResolvedPin], layout: [TaskbarLayoutSlot]? = nil) {
        var ids = Set<UUID>(); var applications = Set<AppDefinition>()
        pins = values.filter { ids.insert($0.pin.id).inserted && applications.insert($0.pin.application).inserted }
        let pinIDs = Set(pins.map { $0.pin.id })
        var seen = Set<TaskbarLayoutSlot>()
        placements = (layout ?? pins.map { .pin($0.pin.id) }).filter { slot in
            guard seen.insert(slot).inserted else { return false }
            switch slot {
            case .pin(let id): return pinIDs.contains(id)
            case .application(let app, _): return app.url.isFileURL && !app.bundleID.isEmpty
            }
        }.map { .saved($0) }
        for pin in pins where !placements.contains(.saved(.pin(pin.pin.id))) {
            placements.append(.saved(.pin(pin.pin.id)))
        }
        processPlacements.removeAll()
        sortPinsByLayout()
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

    /// Used to persist the exact intended layout before publishing a pin addition.
    func layoutAddingPin(_ id: UUID, replacing button: TaskbarButtonID? = nil) -> [TaskbarPlacement] {
        var next = placements
        let newPlacement = TaskbarPlacement.saved(.pin(id))
        if let button, let old = buttonPlacements[button], let index = next.firstIndex(of: old) {
            next[index] = newPlacement
        } else {
            next.append(newPlacement)
        }
        return next
    }

    @discardableResult func add(_ pin: ResolvedPin, replacing button: TaskbarButtonID? = nil) -> Bool {
        guard !pins.contains(where: { $0.pin.application == pin.pin.application || $0.pin.id == pin.pin.id }) else { return false }
        let next = layoutAddingPin(pin.pin.id, replacing: button)
        pins.append(pin)
        placements = next
        // A formerly temporary process can now be represented by the new pin.
        if let button, case .instance(let instance) = button { processPlacements[instance] = nil }
        sortPinsByLayout()
        compose(preferActivePin: pin.pin.id)
        return true
    }

    func layoutRemovingPin(_ id: UUID) -> [TaskbarPlacement] {
        guard let pin = pins.first(where: { $0.pin.id == id }) else { return placements }
        let old = TaskbarPlacement.saved(.pin(id))
        let replacement = TaskbarPlacement.saved(.application(pin.pin.application, UUID()))
        return placements.map { $0 == old ? replacement : $0 }
    }

    func remove(_ id: UUID) {
        placements = layoutRemovingPin(id)
        pins.removeAll { $0.pin.id == id }
        compose()
    }

    /// Move a pin relative to the other pins, keeping intervening live buttons.
    func layoutMovingPin(_ id: UUID, to index: Int) -> [TaskbarPlacement] {
        let ids = pins.map { $0.pin.id }
        guard let old = ids.firstIndex(of: id) else { return placements }
        var reordered = ids
        let item = reordered.remove(at: old)
        reordered.insert(item, at: min(max(0, index), reordered.count))
        guard let targetIndex = reordered.firstIndex(of: id) else { return placements }
        var next = placements
        let moving = TaskbarPlacement.saved(.pin(id))
        next.removeAll { $0 == moving }
        if targetIndex + 1 < reordered.count,
           let destination = next.firstIndex(of: .saved(.pin(reordered[targetIndex + 1]))) {
            next.insert(moving, at: destination)
        } else if targetIndex > 0,
                  let destination = next.firstIndex(of: .saved(.pin(reordered[targetIndex - 1]))) {
            next.insert(moving, at: destination + 1)
        } else {
            next.insert(moving, at: 0)
        }
        return next
    }

    func move(_ id: UUID, to index: Int) { setLayout(layoutMovingPin(id, to: index)) }

    /// toIndex is a gap between visible buttons, before removing the source.
    /// Hidden application slots stay in their relative order.
    func layoutMovingButton(_ id: TaskbarButtonID, toVisibleIndex toIndex: Int) -> [TaskbarPlacement]? {
        guard let source = buttonPlacements[id],
              let oldVisible = snapshot.buttons.firstIndex(where: { $0.id == id }) else { return nil }
        var next = placements
        guard let oldPlacement = next.firstIndex(of: source) else { return nil }
        next.remove(at: oldPlacement)
        let otherButtons = snapshot.buttons.filter { $0.id != id }
        var desired = min(max(0, toIndex), snapshot.buttons.count)
        if desired > oldVisible { desired -= 1 }
        desired = min(max(0, desired), otherButtons.count)
        if desired < otherButtons.count,
           let anchor = buttonPlacements[otherButtons[desired].id],
           let destination = next.firstIndex(of: anchor) {
            next.insert(source, at: destination)
        } else if let last = otherButtons.last, let anchor = buttonPlacements[last.id],
                  let destination = next.firstIndex(of: anchor) {
            next.insert(source, at: destination + 1)
        } else {
            next.insert(source, at: 0)
        }
        return next
    }

    func setLayout(_ value: [TaskbarPlacement]) {
        placements = value
        sortPinsByLayout()
        compose()
    }

    @discardableResult func relink(_ id: UUID, to replacement: ResolvedPin) -> Bool {
        guard let index = pins.firstIndex(where: { $0.pin.id == id }),
              !pins.contains(where: { $0.pin.id != id && $0.pin.application == replacement.pin.application }) else { return false }
        let pin = replacement.pin
        pins[index] = ResolvedPin(pin: Pin(id: id, application: pin.application, name: pin.name, bookmark: pin.bookmark),
                                  availability: replacement.availability, recoveryNote: replacement.recoveryNote)
        assignments[id] = nil; compose(); return true
    }
    func instance(for button: TaskbarButtonID) -> InstanceID? { snapshot.buttons.first { $0.id == button }?.instance?.id }
    private static func earlier(_ a: Instance, _ b: Instance) -> Bool {
        a.id.startDate == b.id.startDate ? a.id.pid < b.id.pid : a.id.startDate < b.id.startDate
    }

    private func sortPinsByLayout() {
        var ranks: [UUID: Int] = [:]
        for (index, placement) in placements.enumerated() {
            if case .saved(.pin(let id)) = placement { ranks[id] = index }
        }
        pins.sort { (ranks[$0.pin.id] ?? Int.max) < (ranks[$1.pin.id] ?? Int.max) }
    }

    private func compose(preferActivePin: UUID? = nil) {
        let oldSaved = savedLayout
        let byID = Dictionary(uniqueKeysWithValues: instances.map { ($0.id, $0) })
        let pinIDs = Set(pins.map { $0.pin.id })
        assignments = assignments.filter { pinIDs.contains($0.key) }
        var used = Set<InstanceID>()
        var buttons: [TaskbarButton] = []
        var buttonSlots: [TaskbarButtonID: TaskbarPlacement] = [:]
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
            let preferred = preferActivePin == pin.id ? matches.first(where: { $0.id == active }) : nil
            let instance = previous ?? preferred ?? matches.first
            assignments[pin.id] = instance?.id
            if let instance { used.insert(instance.id) }
            let button = TaskbarButton(id: .pin(pin.id), pinID: pin.id, application: pin.application,
                                       instance: instance, name: instance?.name ?? pin.name,
                                       ordinal: instance.map(ordinal), isActive: instance?.id == active && instance != nil,
                                       availability: resolved.availability)
            buttons.append(button)
            let slot = TaskbarPlacement.saved(.pin(pin.id))
            buttonSlots[button.id] = slot
            if !placements.contains(slot) { placements.append(slot) }
        }
        let temporaryIDs = Set(order.filter { !used.contains($0) && byID[$0] != nil })
        processPlacements = processPlacements.filter { temporaryIDs.contains($0.key) }
        placements.removeAll { placement in
            if case .temporary(let instance) = placement { return !temporaryIDs.contains(instance) }
            return false
        }
        var taken = Set<TaskbarPlacement>(buttonSlots.values)
        // Keep exact live-process placements first, even when a process list is reordered.
        for id in order where temporaryIDs.contains(id) {
            guard let instance = byID[id], let slot = processPlacements[id] else { continue }
            let matches: Bool
            switch slot {
            case .saved(.application(let app, _)): matches = instance.definition == app
            case .temporary(let previousID): matches = instance.definition == nil && previousID == id
            default: matches = false
            }
            if !matches || !placements.contains(slot) || !taken.insert(slot).inserted { processPlacements[id] = nil }
        }
        for id in order where temporaryIDs.contains(id) {
            guard let instance = byID[id] else { continue }
            let slot: TaskbarPlacement
            if let existing = processPlacements[id] {
                slot = existing
            } else if let app = instance.definition {
                let available = placements.first { placement in
                    if case .saved(.application(let definition, _)) = placement {
                        return definition == app && !taken.contains(placement)
                    }
                    return false
                }
                slot = available ?? .saved(.application(app, UUID()))
            } else {
                slot = .temporary(id)
            }
            if !placements.contains(slot) { placements.append(slot) }
            processPlacements[id] = slot
            taken.insert(slot)
            let button = TaskbarButton(id: .instance(id), pinID: nil, application: instance.definition,
                                       instance: instance, name: instance.name, ordinal: ordinal(instance),
                                       isActive: id == active, availability: .available)
            buttons.append(button); buttonSlots[button.id] = slot
        }
        let ranks = Dictionary(uniqueKeysWithValues: placements.enumerated().map { ($0.element, $0.offset) })
        buttons.sort { (ranks[buttonSlots[$0.id]!] ?? Int.max) < (ranks[buttonSlots[$1.id]!] ?? Int.max) }
        buttonPlacements = buttonSlots
        snapshot = TaskbarSnapshot(buttons: buttons, activeInstance: active)
        changed?(snapshot)
        if savedLayout != oldSaved { discoveredLayout?() }
    }
}
