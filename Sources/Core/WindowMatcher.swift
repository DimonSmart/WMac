import CoreGraphics
import Foundation

// AX windows and graphical capture IDs live in different namespaces.
// A graphics ID is never an actionable identifier and is only accepted
// after a unique, process-scoped comparison against the entire AX set.
struct GraphicalWindow: Sendable {
    let id: CGWindowID
    let title: String
    let frame: CGRect
    var processID: pid_t? = nil
}

enum WindowMatchResult: Equatable, Sendable {
    case matched(CGWindowID)
    case unmatched
    case ambiguous
}

enum GraphicsMatchStatus: Equatable, Sendable {
    case confirmedGraphicsMatch(CGWindowID)
    case ambiguous
    case semanticOnly
    case unavailable
}

enum GraphicsMatchReason: String, Sendable {
    case uniqueTitleAndGeometry
    case unavailableSource
    case invalidAXGeometry
    case missingAXTitle
    case noGraphicsWindows
    case titleMismatch
    case geometryMismatch
    case multipleGraphicsCandidates
    case sharedGraphicsCandidate
    case duplicateGraphicsID
}

struct GraphicsResolution: Sendable {
    let identity: WindowIdentity
    let observedRevision: UInt64
    let associationGeneration: UUID
    let status: GraphicsMatchStatus
    let reason: GraphicsMatchReason
    let candidateIDs: [CGWindowID]
}

enum WindowMatcher {
    // All inputs must belong to this lifetime. A capture caller additionally
    // verifies that the OS process still has the same PID and launch date.
    static func resolve(_ windows: [WindowReference], to images: [GraphicalWindow],
                        sourcesAvailable: Bool = true) -> [UUID: GraphicsResolution] {
        let generation = UUID()
        let process = windows.first?.instance
        let graphics = images.filter { image in
            image.processID == nil || image.processID == process?.pid
        }
        var candidates: [UUID: [CGWindowID]] = [:]
        for window in windows {
            guard window.instance == process, let frame = window.frame, valid(frame), !window.title.isEmpty else {
                candidates[window.id] = []
                continue
            }
            candidates[window.id] = graphics.filter { image in
                valid(image.frame) && !image.title.isEmpty && image.title == window.title &&
                abs(frame.minX - image.frame.minX) <= 12 &&
                abs(frame.minY - image.frame.minY) <= 12 &&
                abs(frame.width - image.frame.width) <= 28 &&
                abs(frame.height - image.frame.height) <= 28
            }.map(\.id)
        }

        var result: [UUID: GraphicsResolution] = [:]
        for window in windows {
            let choices = candidates[window.id] ?? []
            let status: GraphicsMatchStatus
            let reason: GraphicsMatchReason
            if !sourcesAvailable {
                status = .unavailable; reason = .unavailableSource
            } else if window.frame.map(valid) != true {
                status = .semanticOnly; reason = .invalidAXGeometry
            } else if window.title.isEmpty {
                status = .semanticOnly; reason = .missingAXTitle
            } else if graphics.isEmpty {
                status = .semanticOnly; reason = .noGraphicsWindows
            } else if choices.isEmpty {
                status = .semanticOnly
                reason = graphics.contains(where: { $0.title == window.title }) ? .geometryMismatch : .titleMismatch
            } else if choices.count != 1 {
                status = .ambiguous
                reason = Set(choices).count != choices.count ? .duplicateGraphicsID : .multipleGraphicsCandidates
            } else if candidates.contains(where: { $0.key != window.id && $0.value.contains(choices[0]) }) {
                status = .ambiguous; reason = .sharedGraphicsCandidate
            } else {
                status = .confirmedGraphicsMatch(choices[0]); reason = .uniqueTitleAndGeometry
            }
            result[window.id] = GraphicsResolution(identity: window.identity, observedRevision: window.stateRevision,
                                                   associationGeneration: generation, status: status,
                                                   reason: reason, candidateIDs: choices)
        }
        return result
    }

    // Preserve the existing small public test surface.
    static func match(_ windows: [WindowReference], to images: [GraphicalWindow]) -> [UUID: WindowMatchResult] {
        resolve(windows, to: images).mapValues { resolution in
            switch resolution.status {
            case .confirmedGraphicsMatch(let id): .matched(id)
            case .ambiguous: .ambiguous
            case .semanticOnly, .unavailable: .unmatched
            }
        }
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite &&
        frame.width.isFinite && frame.height.isFinite &&
        frame.width > 0 && frame.height > 0
    }
}
