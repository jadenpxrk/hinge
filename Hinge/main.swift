import AppKit
import Darwin
import Foundation

private let usage = """
Hinge — keep a MacBook awake with the lid closed (screen off, machine on).

Usage:
  Hinge                  Menu-bar app
  Hinge --on             Start a session. Wait until you stop it or the session stops.
  Hinge --off            Tell the owner to restore lid sleep. Wait for confirmation.
  Hinge --restore-sleep  Same as --off
  Hinge --toggle         Do --off if a session exists. If not, do --on.
  Hinge --status         Show the lid, sleep, battery, and recovery state
  Hinge --probe          Show connection and hinge-sensor data. Change nothing.
  Hinge --watchdog       Do one recovery check (the LaunchAgent uses this)
  Hinge --help

URL commands: hinge://arm, hinge://disarm, hinge://toggle
"""

private var signalSources: [AnyObject] = []

@MainActor
private func installSignalRestore() {
    atexit { SessionController.restoreAtExit() }
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            // The source is bound to the main queue; restore through the controller and exit without atexit.
            MainActor.assumeIsolated {
                SessionController.shared.perform(.restoreLocal) { ok in _exit(ok ? 0 : 1) }
            }
        }
        src.resume()
        signalSources.append(src)
    }
}

@MainActor
private func runHeadlessArm() -> Int32 {
    installSignalRestore()
    let controller = SessionController.shared
    var started = false
    var failed = false
    controller.onChange = {
        if started, controller.busy == nil, !controller.state.armed, !controller.state.needsRecovery {
            failed = controller.state.error != nil
            if let notice = controller.state.notice { fputs(notice + "\n", stderr) }
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }
    controller.startMonitoring()
    controller.perform(.arm(.persistent)) { ok in
        started = true
        failed = !ok
        print(controller.state.detail)
        fflush(stdout)
        if !ok || !controller.state.armed { CFRunLoopStop(CFRunLoopGetMain()) }
    }
    CFRunLoopRun()
    controller.perform(.restoreLocal) { _ in CFRunLoopStop(CFRunLoopGetMain()) }
    CFRunLoopRun()
    controller.stopMonitoring()
    return failed ? 1 : 0
}

private func probe() throws -> Int32 {
    print("Hinge diagnostics (no sleep settings changed)")
    print("  \(Sysctl.machine)  macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    let spi = ClamshellSPI()
    print("  Power-management connection: \(spi.open() ? "available" : "unavailable")")
    spi.close()
    let hinge = LidAngle()
    hinge.start()
    if let angle = hinge.read() {
        print("  Lid angle: \(String(format: "%.1f", angle))°")
    } else {
        print("  No hinge sensor available. Use Keep Awake from the menu.")
    }
    hinge.stop()
    try printStatus()
    return 0
}

private func fmt(_ b: Bool?) -> String {
    guard let b else { return "missing" }
    return b ? "Yes" : "No"
}
enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix(size).prefix { $0 != 0 }, as: UTF8.self)
    }

    static var machine: String {
        let parts = [string("hw.model"), string("machdep.cpu.brand_string")].compactMap { $0 }
        return parts.isEmpty ? "unknown model" : parts.joined(separator: ", ")
    }
}

private func printStatus() throws {
    print((try StateFile.readDirty()) == nil ? "recoveryRecord=false" : "recoveryRecord=true")
    let snap = IOPM.snapshot()
    print("AppleClamshellState=\(fmt(snap.lidClosed))")
    print("AppleClamshellCausesSleep=\(fmt(snap.clamshellCausesSleep))")
    print("SleepDisabled=\(fmt(snap.sleepDisabled))")
    let battery = Battery.read()
    if let pct = battery.percent {
        print("battery=\(pct)% source=\(battery.onBattery == true ? "battery" : "AC/unknown")")
    }
}

@MainActor
private func runGUI() -> Int32 {
    installSignalRestore()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    return 0
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("-h") || args.contains("--help") {
    print(usage)
    exit(0)
}

let cmd = args.first ?? ""
do {
    switch cmd {
    case "":
        exit(runGUI())
    case "--on":
        exit(runHeadlessArm())
    case "--off", "--restore-sleep":
        try Watchdog.requestStop()
        print("Hinge's sleep changes have been restored.")
        exit(0)
    case "--toggle":
        if try StateFile.readDirty() != nil {
            try Watchdog.requestStop()
            print("Hinge's sleep changes have been restored.")
            exit(0)
        }
        exit(runHeadlessArm())
    case "--status":
        try printStatus()
        exit(0)
    case "--probe":
        exit(try probe())
    case "--watchdog":
        print(try Watchdog.runOnce())
        exit(0)
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        fputs("unknown argument: \(cmd)\n\n\(usage)\n", stderr)
        exit(2)
    }
} catch {
    fputs(error.localizedDescription + "\n", stderr)
    exit(1)
}
