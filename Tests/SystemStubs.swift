import AppKit
import Foundation

enum TestSystem {
    static var spiEnableOK = true
    static var spiRestoreOK = true
    static var idleOK = true
    static var launchOK = true
    static var commands: [(String, [String])] = []
    static var lidClosed = false
    static var externalDisplay = false
    static var commandDelay: TimeInterval = 0
    static var spiWrites = 0

    static func flag(_ name: String) -> Bool {
        (try? String(contentsOf: Paths.supportDir.appendingPathComponent(name), encoding: .utf8)) == "1"
    }
    static func setFlag(_ name: String, _ value: Bool) {
        try! (value ? "1" : "0").write(to: Paths.supportDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

final class ClamshellSPI {
    func setLidSleepDisabled(_ disabled: Bool) -> Bool {
        guard disabled ? TestSystem.spiEnableOK : TestSystem.spiRestoreOK else { return false }
        TestSystem.spiWrites += 1
        TestSystem.setFlag("spi", disabled)
        return true
    }
}

final class LidMonitor {
    static var current: LidMonitor?
    var onChange: ((Bool) -> Void)?
    func start() { Self.current = self }
    func stop() {}
}
final class LidAngle {
    static var reads = 0
    static var starts = 0
    var available = false
    func start() { Self.starts += 1; available = true }
    func stop() { available = false }
    func read() -> Double? { Self.reads += 1; return available ? 100 : nil }
}
final class PowerMonitor {
    var onChange: (() -> Void)?
    func start() {}
    func stop() {}
}
enum Battery {
    static var value = BatteryReading(percent: 100, onBattery: false)
    static func read() -> BatteryReading { value }
}
enum Thermals { static var state: ProcessInfo.ThermalState = .nominal }
enum PowerSleep {
    static var succeeds = true
    static var calls = 0
    static func sleepNow() -> Bool { calls += 1; return succeeds }
}
enum IOPM {
    struct Snapshot {
        var lidClosed: Bool?
        var clamshellCausesSleep: Bool?
        var sleepDisabled: Bool?
    }
    static func snapshot() -> Snapshot {
        Snapshot(lidClosed: TestSystem.lidClosed, clamshellCausesSleep: !TestSystem.flag("spi"),
                 sleepDisabled: TestSystem.flag("pmset"))
    }
}
enum IdleHold {
    static var held = false
    static func take() -> Bool { held = TestSystem.idleOK; return held }
    static func release() { held = false }
}
enum Defaults {
    static let batteryFloors = Array(stride(from: 0, through: 50, by: 5))
    static var batteryFloor = 0
}
enum Displays { static var hasExternal: Bool { TestSystem.externalDisplay } }
enum ArmedHUD {
    static func showArmed(mode: ArmMode) {}
    static func hide() {}
}

enum TestCommands {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (Int32, String) {
        if TestSystem.commandDelay > 0 { Thread.sleep(forTimeInterval: TestSystem.commandDelay) }
        TestSystem.commands.append((path, args))
        if path == "/bin/launchctl" { return (TestSystem.launchOK ? 0 : 1, "test launchctl") }
        fatalError("Unexpected system call: \(path) \(args)")
    }
}

// This is the same boundary used by production, with isolated paths and commands.
typealias SystemCommands = TestCommands
enum Paths {
    static let supportDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    static let dirtyURL = supportDir.appendingPathComponent("dirty")
    static let stopURL = supportDir.appendingPathComponent("stop")
    static let launchAgentLabel = "dev.hinge.watchdog"
    static let launchAgentURL = supportDir.appendingPathComponent("watchdog.plist")
    static var executablePath: String { CommandLine.arguments[0] }
}
