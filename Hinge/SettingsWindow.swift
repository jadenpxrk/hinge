import AppKit

final class SettingsWindow: NSWindowController {
    private let controller: SessionController
    private let battery = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")

    init(controller: SessionController) {
        self.controller = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Hinge Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
            ])
        }
        func label(_ text: String) {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: 12)
            field.textColor = .secondaryLabelColor
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        status.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        label("Option + close: one session  •  Menu: until turned off")
        battery.addItems(withTitles: Defaults.batteryFloors.map { $0 == 0 ? "Battery protection: Off" : "Stop at \($0)% battery" })
        battery.target = self
        battery.action = #selector(changeBattery)
        battery.setAccessibilityLabel("Battery protection threshold")
        stack.addArrangedSubview(battery)
        label("Safety stops the session for serious heat or your selected battery level.")
        label("External displays pause and resume the session automatically.")
        window.center()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        status.stringValue = controller.busy ?? controller.state.error ?? controller.state.title
        battery.selectItem(at: Defaults.batteryFloors.firstIndex(of: Defaults.batteryFloor) ?? 0)
        let enabled = controller.busy == nil
        battery.isEnabled = enabled
    }

    @objc private func changeBattery() { Defaults.batteryFloor = Defaults.batteryFloors[battery.indexOfSelectedItem]; controller.perform(.refresh) }
}
