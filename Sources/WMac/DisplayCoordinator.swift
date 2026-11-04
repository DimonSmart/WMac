import AppKit

struct MenuCommand { let capture: ButtonCapture; let action: String }

@MainActor final class DisplayCoordinator {
    unowned let runtime: TaskbarDelegate
    var hidden = false
    private var panels: [UInt32: TaskbarPanel] = [:]
    var hasUsablePanels: Bool { !hidden && !panels.isEmpty }
    init(runtime: TaskbarDelegate) { self.runtime = runtime }
    func reconcile() {
        runtime.previews.close()
        let screens = NSScreen.screens.filter { runtime.settings.value.allDisplays || ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() }.compactMap { screen -> (DisplayLayout, NSScreen)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (DisplayLayout(id: id.uint32Value, frame: screen.frame), screen)
        }
        let delta = DisplayLayout.reconcile(owned: Set(panels.keys), screens: screens.map(\.0))
        for id in delta.removed { panels.removeValue(forKey: id)?.close() }
        for (layout, _) in screens {
            let panel = panels[layout.id] ?? TaskbarPanel(runtime: runtime)
            panels[layout.id] = panel
            var frame = layout.panelFrame(height: runtime.settings.value.height)
            // Explicit developer harness for real overflow testing without fake buttons.
            if let index = CommandLine.arguments.firstIndex(of: "--panel-test-width"),
               CommandLine.arguments.indices.contains(index + 1),
               let width = Double(CommandLine.arguments[index + 1]), width >= 400 {
                frame.size.width = min(frame.width, width); frame.origin.x = layout.frame.midX - frame.width / 2
            }
            panel.appearance = runtime.settings.value.theme == .system ? nil : NSAppearance(named: runtime.settings.value.theme == .dark ? .darkAqua : .aqua)
            panel.bar.applyOpacity(runtime.settings.value.opacity)
            panel.setFrame(frame, display: true)
            if hidden { panel.orderOut(nil) } else { panel.orderFront(nil) }
        }
        render(runtime.coordinator.snapshot)
    }
    func render(_ snapshot: TaskbarSnapshot) { for panel in panels.values { panel.bar.render(snapshot) } }
    func anchor(for capture: ButtonCapture) -> NSView? {
        let choices = panels.values.compactMap { $0.bar.anchor(for: capture) }.filter { view in
            guard view.window?.isVisible == true, !view.isHiddenOrHasHiddenAncestor else { return false }
            // An overflowed button is still in the hierarchy but is not a usable popup anchor.
            return view.visibleRect.intersects(view.bounds)
        }
        let pointer = NSEvent.mouseLocation
        return choices.first(where: { $0.window?.frame.contains(pointer) == true }) ?? choices.first
    }
    func close() { for panel in panels.values { panel.close() }; panels.removeAll() }
}
