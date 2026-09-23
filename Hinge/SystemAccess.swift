import Foundation
import CoreGraphics

// Production system boundary. Regression tests provide their own paths,
// command runner, preferences, and hardware implementations at compile time.
typealias SystemCommands = Shell

enum Paths {
    static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hinge", isDirectory: true)
    static let dirtyURL = supportDir.appendingPathComponent("dirty")
    static let stopURL = supportDir.appendingPathComponent("stop")
    static let launchAgentLabel = "dev.hinge.watchdog"
    static let launchAgentURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LaunchAgents/\(launchAgentLabel).plist")
    static var executablePath: String { Bundle.main.executableURL?.path ?? CommandLine.arguments[0] }
}

enum Defaults {
    static let batteryFloors = Array(stride(from: 0, through: 50, by: 5))
    static var batteryFloor: Int {
        get {
            guard UserDefaults.standard.object(forKey: "Hinge.batteryFloor") != nil else { return 10 }
            let value = UserDefaults.standard.integer(forKey: "Hinge.batteryFloor")
            return batteryFloors.contains(value) ? value : 10
        }
        set { UserDefaults.standard.set(batteryFloors.contains(newValue) ? newValue : 0, forKey: "Hinge.batteryFloor") }
    }
}

enum Displays {
    static var hasExternal: Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}
