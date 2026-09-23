import AppKit
import CoreGraphics

/// Brief confirmation only. This panel never replaces the macOS Lock Screen.
@MainActor
enum ArmedHUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func showArmed(mode: ArmMode) {
        hide()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let screen = NSScreen.screens.first(where: { screen in
                  guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                  return CGDisplayIsBuiltin(id.uint32Value) != 0
              }) else { return }
        let frame = NSRect(x: screen.visibleFrame.midX - 130, y: screen.visibleFrame.maxY - 70, width: 260, height: 44)
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        let message = mode == .persistent ? "On until you turn it off" : "On until you reopen the lid"
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.frame = NSRect(x: 12, y: 13, width: 236, height: 18)
        background.addSubview(label)
        window.contentView = background
        panel = window
        window.orderFrontRegardless()
        let work = DispatchWorkItem { hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    static func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.close()
        panel = nil
    }
}
