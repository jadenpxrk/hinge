import AppIntents
import Foundation

struct HingeArmIntent: AppIntent {
    static let title: LocalizedStringResource = "Keep Awake with Hinge"
    static let description = IntentDescription("Keep the Mac on when you close the lid, until you turn it off.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await SessionController.shared.result(for: .arm(.persistent))
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct HingeDisarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off Hinge"
    static let description = IntentDescription("Stop the session and restore normal lid sleep.")
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
        AppShortcut(intent: HingeArmIntent(), phrases: ["Keep awake with \(.applicationName)"], shortTitle: "Keep Awake", systemImageName: "macbook")
        AppShortcut(intent: HingeDisarmIntent(), phrases: ["Turn off \(.applicationName)"], shortTitle: "Turn Off", systemImageName: "macbook")
        AppShortcut(intent: HingeToggleIntent(), phrases: ["Toggle \(.applicationName)"], shortTitle: "Toggle", systemImageName: "macbook")
        AppShortcut(intent: HingeStatusIntent(), phrases: ["\(.applicationName) status"], shortTitle: "Status", systemImageName: "macbook")
    }
}
