import AppIntents
import Foundation

struct HingeArmIntent: AppIntent {
    static let title: LocalizedStringResource = "Arm Hinge"
    static let description = IntentDescription("Keep the Mac awake with the lid closed until disarmed.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await SessionController.shared.result(for: .arm(.persistent))
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct HingeDisarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Disarm Hinge"
    static let description = IntentDescription("Restore normal lid-close sleep.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await SessionController.shared.result(for: .turnOff)
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct HingeToggleIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Hinge"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await SessionController.shared.result(for: .toggle)
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct HingeStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Hinge Status"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let line = await SessionController.shared.result(for: .refresh)
        return .result(value: line, dialog: IntentDialog(stringLiteral: line))
    }
}

struct HingeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: HingeArmIntent(), phrases: ["Arm \(.applicationName)"], shortTitle: "Arm", systemImageName: "macbook")
        AppShortcut(intent: HingeDisarmIntent(), phrases: ["Disarm \(.applicationName)"], shortTitle: "Disarm", systemImageName: "macbook")
        AppShortcut(intent: HingeToggleIntent(), phrases: ["Toggle \(.applicationName)"], shortTitle: "Toggle", systemImageName: "macbook")
        AppShortcut(intent: HingeStatusIntent(), phrases: ["\(.applicationName) status"], shortTitle: "Status", systemImageName: "macbook")
    }
}
