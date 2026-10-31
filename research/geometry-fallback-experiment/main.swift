import AppKit
import ApplicationServices
@preconcurrency import ScreenCaptureKit

func closeFrame(_ a: CGRect?, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
    guard let a, [a.minX, a.minY, a.width, a.height, b.minX, b.minY, b.width, b.height].allSatisfy(\.isFinite), a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return false }
    return abs(a.minX-b.minX) <= tolerance && abs(a.minY-b.minY) <= tolerance && abs(a.width-b.width) <= tolerance && abs(a.height-b.height) <= tolerance
}
func proposed(_ windows: [WindowReference], _ graphics: [GraphicalWindow]) -> [UUID: WindowMatchResult] {
    var result = WindowMatcher.match(windows, to: graphics)
    for w in windows where result[w.id] == .unmatched && !w.isMinimized {
        let choices = graphics.filter { closeFrame(w.frame, $0.frame) }
        guard choices.count == 1 else { if choices.count > 1 { result[w.id] = .ambiguous }; continue }
        let g = choices[0]
        guard windows.filter({ closeFrame($0.frame, g.frame) }).count == 1,
              !result.contains(where: { $0.key != w.id && $0.value == .matched(g.id) }) else { result[w.id] = .ambiguous; continue }
        result[w.id] = .matched(g.id)
    }
    return result
}
func rect(_ r: CGRect?) -> [Double] { guard let r else { return [] }; return [r.minX, r.minY, r.width, r.height].map(Double.init) }

@MainActor final class ExperimentDelegate: NSObject, NSApplicationDelegate {
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("results.json")
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await run(); NSApp.terminate(nil) }
    }
    func run() async {
        var report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "axTrusted": AXIsProcessTrusted(), "screenCapture": CGPreflightScreenCaptureAccess()]
        let identity = InstanceID(pid: 1, launchDate: Date(timeIntervalSince1970: 0))
        let left = CGRect(x: 0, y: 50, width: 800, height: 600)
        let right = CGRect(x: 850, y: 50, width: 800, height: 600)
        func w(_ title: String, _ frame: CGRect?, minimized: Bool = false) -> WindowReference { WindowReference(id: UUID(), instance: identity, title: title, isMinimized: minimized, isFocused: false, canMinimize: true, frame: frame) }
        func g(_ id: CGWindowID, _ title: String, _ frame: CGRect) -> GraphicalWindow { GraphicalWindow(id: id, title: title, frame: frame) }
        var cases: [[String: Any]] = []
        func scenario(_ name: String, _ ax: [WindowReference], _ cg: [GraphicalWindow], _ expected: [WindowMatchResult]) {
            let old = WindowMatcher.match(ax, to: cg), new = proposed(ax, cg)
            let actual = ax.map { new[$0.id] ?? .unmatched }
            cases.append(["name": name, "old": ax.map { String(describing: old[$0.id] ?? .unmatched) }, "proposed": actual.map { String(describing: $0) }, "expected": expected.map { String(describing: $0) }, "pass": actual == expected])
        }
        scenario("unique geometry, decorated title", [w("Document - Profile",left)], [g(1,"Document",left)], [.matched(1)])
        scenario("unique geometry, empty SC title", [w("Document",left)], [g(1,"",left)], [.matched(1)])
        scenario("two SC windows same frame", [w("Document",left)], [g(1,"A",left),g(2,"B",left)], [.ambiguous])
        scenario("two AX windows same frame", [w("A",left),w("B",left)], [g(1,"X",left)], [.ambiguous,.ambiguous])
        scenario("minimized target", [w("A",left,minimized:true)], [g(1,"X",left)], [.unmatched])
        scenario("missing geometry", [w("A",nil)], [g(1,"X",left)], [.unmatched])
        scenario("outside exact tolerance", [w("A",left)], [g(1,"X",left.offsetBy(dx:2,dy:0))], [.unmatched])
        scenario("stale AX, two distinct windows swapped positions", [w("A",left),w("B",right)], [g(1,"A",right),g(2,"B",left)], [.unmatched,.unmatched])
        scenario("stale AX, closed window replaced at same frame", [w("Closed document",left)], [g(2,"Different document",left)], [.unmatched])
        report["synthetic"] = cases
        if AXIsProcessTrusted() && CGPreflightScreenCaptureAccess() {
            do {
                let service = AccessibilityService()
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly:false)
                let rows = CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] ?? []
                var live: [[String:Any]] = []
                let bundles = ["com.microsoft.edgemac", "com.dimonsmart.csharpfar", "com.apple.Notes", "com.apple.Safari"]
                for app in NSWorkspace.shared.runningApplications where bundles.contains(app.bundleIdentifier ?? "") {
                    guard let launched = app.launchDate else { continue }
                    let id = InstanceID(pid:app.processIdentifier,launchDate:launched)
                    guard case .windows(let windows) = await service.windows(for:id) else { continue }
                    let sources = content.windows.filter { $0.owningApplication?.processID == id.pid }
                    let geometry = sources.compactMap { source -> GraphicalWindow? in
                        guard let row = rows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == source.windowID && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == id.pid }), let d = row[kCGWindowBounds as String] as? NSDictionary else { return nil }
                        var frame = CGRect.zero
                        guard CGRectMakeWithDictionaryRepresentation(d as CFDictionary,&frame) else { return nil }
                        return GraphicalWindow(id:source.windowID,title:source.title ?? "",frame:frame)
                    }
                    let old = WindowMatcher.match(windows,to:geometry), new = proposed(windows,geometry)
                    for (index,window) in windows.enumerated() {
                        var item: [String:Any] = ["bundle":app.bundleIdentifier ?? "", "pid":id.pid, "axIndex":index, "axFrame":rect(window.frame), "minimized":window.isMinimized, "old":String(describing:old[window.id] ?? .unmatched), "proposed":String(describing:new[window.id] ?? .unmatched)]
                        item["exactCandidates"] = geometry.filter { closeFrame(window.frame,$0.frame) }.map { source in
                            func normalize(_ text: String) -> String {
                                String(String.UnicodeScalarView(text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter { $0.properties.generalCategory != .format })).trimmingCharacters(in:.whitespacesAndNewlines)
                            }
                            let marker = " - " + (app.localizedName ?? "")
                            let axNormalized = normalize(window.title)
                            let scNormalized = normalize(source.title)
                            let stripped = axNormalized.range(of:marker,options:.backwards).map { String(axNormalized[..<$0.lowerBound]) } ?? axNormalized
                            return ["id":source.id,"frame":rect(source.frame),"titleEqual":source.title == window.title,"scTitleEmpty":source.title.isEmpty,"axTitleLength":window.title.count,"scTitleLength":source.title.count,"scIsAXPrefix":!source.title.isEmpty && window.title.hasPrefix(source.title),"axIsSCPrefix":!window.title.isEmpty && source.title.hasPrefix(window.title),"normalizedTitleEqual":axNormalized == scNormalized,"titleEqualAfterRemovingApplicationSuffix":stripped == scNormalized,"applicationSuffixFound":stripped != axNormalized,"axFormatScalarCount":window.title.unicodeScalars.filter { $0.properties.generalCategory == .format }.count,"scFormatScalarCount":source.title.unicodeScalars.filter { $0.properties.generalCategory == .format }.count] as [String:Any]
                        }
                        if !window.isMinimized, case .matched(let gid) = new[window.id], let source = sources.first(where: {$0.windowID == gid}) {
                            let config = SCStreamConfiguration(); config.width = 440; config.height = max(1,Int(440*source.frame.height/max(source.frame.width,1)))
                            do {
                                let image = try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:source),configuration:config)
                                item["capture"] = ["width":image.width,"height":image.height,"success":true]
                            } catch { item["capture"] = ["success":false,"error":String(describing:error)] }
                        }
                        live.append(item)
                    }
                }
                report["live"] = live
            } catch { report["error"] = String(describing:error) }
        }
        do { let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]); try data.write(to:output,options:.atomic) } catch { NSLog("Experiment output error: %@",String(describing:error)) }
    }
}
let app = NSApplication.shared
let delegate = ExperimentDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
