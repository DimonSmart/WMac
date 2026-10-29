import CoreGraphics
import Foundation

/// AX references and ScreenCaptureKit capture handles identify windows separately.
/// Match against global kCGWindowBounds geometry so unmatched cards never guess
/// from PID, title, or enumeration order alone.
struct GraphicalWindow: Sendable {
    let id: CGWindowID
    let title: String
    let frame: CGRect
}

enum WindowMatchResult: Equatable, Sendable {
    case matched(CGWindowID)
    case unmatched
    case ambiguous
}

enum WindowMatcher {
    static func match(_ windows: [WindowReference], to images: [GraphicalWindow]) -> [UUID: WindowMatchResult] {
        var candidates: [UUID: [CGWindowID]] = [:]
        for window in windows {
            guard let frame = window.frame, valid(frame), !window.title.isEmpty else {
                candidates[window.id] = []
                continue
            }
            candidates[window.id] = images.filter { image in
                valid(image.frame) && !image.title.isEmpty &&
                image.title == window.title &&
                abs(frame.minX - image.frame.minX) <= 12 &&
                abs(frame.minY - image.frame.minY) <= 12 &&
                abs(frame.width - image.frame.width) <= 28 &&
                abs(frame.height - image.frame.height) <= 28
            }.map(\.id)
        }
        var result: [UUID: WindowMatchResult] = [:]
        for window in windows {
            let choices = candidates[window.id] ?? []
            if choices.isEmpty {
                result[window.id] = .unmatched
            } else if choices.count != 1 {
                result[window.id] = .ambiguous
            } else if candidates.contains(where: { $0.key != window.id && $0.value.contains(choices[0]) }) {
                result[window.id] = .ambiguous
            } else {
                result[window.id] = .matched(choices[0])
            }
        }
        return result
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite &&
        frame.width.isFinite && frame.height.isFinite &&
        frame.width > 0 && frame.height > 0
    }
}
