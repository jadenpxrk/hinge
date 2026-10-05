import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem?
    private let controller = SessionController.shared
    private var settings: SettingsWindow?
    private var wasArmed = false
    private lazy var inactiveMenuBarIcon = makeMenuBarIcon(active: false)
    private lazy var activeMenuBarIcon = makeMenuBarIcon(active: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item?.menu = menu
        controller.onChange = { [weak self] in self?.syncUI() }
        controller.startMonitoring()
        syncUI()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handleURL(url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.perform(.restoreLocal) { [weak self] ok in
            sender.reply(toApplicationShouldTerminate: ok)
            if !ok { self?.showSettings(nil) }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) { controller.stopMonitoring() }

    func menuNeedsUpdate(_ menu: NSMenu) { updateMenu(menu, state: controller.state, busy: controller.busy) }

    func updateMenu(_ menu: NSMenu, state: SessionState, busy: String? = nil) {
        menu.removeAllItems()
        let title = state.needsRecovery ? "Restore Lid Sleep" : (state.canTurnOff ? "Turn Off" : "Keep Awake")
        let primary = NSMenuItem(title: busy ?? title, action: #selector(primaryAction), keyEquivalent: "")
        primary.target = self
        primary.isEnabled = busy == nil
        menu.addItem(primary)
        let status = NSMenuItem(title: String(state.title.prefix(65)), action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.toolTip = state.error ?? state.notice ?? state.title
        menu.addItem(status)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Hinge", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func primaryAction() {
        controller.perform(controller.state.canTurnOff ? .turnOff : .arm(.persistent))
    }

    @objc private func showSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsWindow(controller: controller) }
        settings?.refresh()
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "hinge" else { return }
        let action = (url.host ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        switch action {
        case "disarm", "off": controller.perform(.turnOff)
        case "toggle" where controller.state.canTurnOff: controller.perform(.turnOff)
        case "arm", "toggle":
            let alert = NSAlert()
            alert.messageText = "Allow this link to keep your Mac awake?"
            alert.informativeText = "The Mac stays on when you close the lid. Continue only if you started this action."
            alert.addButton(withTitle: "Keep Awake")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { controller.perform(.arm(.persistent)) }
        default: break
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    private func makeMenuBarIcon(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 3, y: 2.5, width: 3.2, height: 13),
                         xRadius: 1.6, yRadius: 1.6).fill()
            NSBezierPath(roundedRect: NSRect(x: 3, y: 2.5, width: 9.2, height: 3.2),
                         xRadius: 1.6, yRadius: 1.6).fill()

            let dot = NSBezierPath(ovalIn: NSRect(x: 12.3, y: 8.2, width: 3.4, height: 3.4))
            if active {
                dot.fill()
            } else {
                dot.lineWidth = 1.35
                dot.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func syncUI() {
        let state = controller.state
        let activelyKeepingAwake = state.armed && !state.paused
        if activelyKeepingAwake && !wasArmed { ArmedHUD.showArmed(mode: state.armMode) }
        if !activelyKeepingAwake { ArmedHUD.hide() }
        wasArmed = activelyKeepingAwake
        let description = "Hinge — \(controller.busy ?? state.title)"
        item?.button?.image = state.armed || state.needsRecovery ? activeMenuBarIcon : inactiveMenuBarIcon
        item?.button?.contentTintColor = nil
        item?.button?.toolTip = description
        item?.button?.setAccessibilityLabel(description)
        if let menu = item?.menu { updateMenu(menu, state: state, busy: controller.busy) }
        settings?.refresh()
    }
}
