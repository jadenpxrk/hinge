import AppKit
import Darwin
import Foundation

setbuf(stdout, nil)

struct TestFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure(message) }
}
func expectError(_ message: String, _ action: () throws -> Void) throws {
    do { try action() }
    catch { return }
    throw TestFailure(message)
}
func child(_ mode: String) throws -> Process {
    TestSystem.setFlag("ready", false)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = [Paths.supportDir.path, mode]
    try process.run()
    return process
}
func waitForRecord() throws {
    let deadline = Date().addingTimeInterval(5)
    while !TestSystem.flag("ready"), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    try check(TestSystem.flag("ready") && StateFile.readDirty() != nil, "child finished arming and recorded its session")
}

@MainActor
func fresh(_ name: String) throws -> StayEngine {
    StateFile.releaseLock()
    Paths.supportDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent(name)
    try StateFile.prepareDirectory()
    TestSystem.spiEnableOK = true
    TestSystem.spiRestoreOK = true
    TestSystem.idleOK = true
    TestSystem.launchOK = true
    TestSystem.commands = []
    TestSystem.lidClosed = false
    TestSystem.externalDisplay = false
    TestSystem.commandDelay = 0
    TestSystem.spiWrites = 0
    Battery.value = BatteryReading(percent: 100, onBattery: false)
    Thermals.state = .nominal
    Defaults.batteryFloor = 0
    PowerSleep.succeeds = true
    PowerSleep.calls = 0
    IdleHold.held = false
    LidMonitor.current = nil
    LidAngle.reads = 0
    LidAngle.starts = 0
    return StayEngine()
}

@MainActor
func runTests() throws {
    try StateFile.prepareDirectory()
    let engine = StayEngine()
    let mode = CommandLine.arguments[2]
    if mode == "owner" {
        guard engine.arm() else { fatalError(engine.lastError ?? "arm failed") }
        TestSystem.setFlag("ready", true)
        let deadline = Date().addingTimeInterval(9)
        while engine.armed && Date() < deadline {
            engine.tickOnce()
            Thread.sleep(forTimeInterval: 0.05)
        }
        try check(!engine.armed, "remote stop disarmed the owning process")
        Thread.sleep(forTimeInterval: 0.1)
        engine.tickOnce()
        try check(!TestSystem.flag("spi"), "owner does not re-arm after remote stop")
        exit(0)
    }
    if mode == "crash" {
        guard engine.arm() else { fatalError(engine.lastError ?? "arm failed") }
        _exit(0) // No cleanup: exercise kernel lock release and watchdog recovery.
    }
    if mode == "pausedcrash" {
        TestSystem.externalDisplay = true
        guard engine.arm(), engine.paused else { fatalError(engine.lastError ?? "paused arm failed") }
        _exit(0) // No cleanup: the kernel must release a paused owner's lock too.
    }
    if mode == "contender" {
        try check(!engine.arm(), "a second process cannot claim an active session")
        try check(!StateFile.ownsLock, "failed contender does not own the session lock")
        exit(0)
    }
    if mode == "hung" {
        guard engine.arm() else { fatalError(engine.lastError ?? "arm failed") }
        TestSystem.setFlag("ready", true)
        Thread.sleep(forTimeInterval: 0.7)
        _exit(0)
    }
    if mode == "churn" {
        guard try StateFile.acquireLock() else { fatalError("churn lock") }
        for _ in 0..<300 {
            try StateFile.markDirty(session: UUID())
            try StateFile.clearDirty()
        }
        StateFile.releaseLock()
        exit(0)
    }

    let tests: [(String, () throws -> Void)] = [
        ("restoreFailureAndMenu", testRestoreFailureAndMenu),
        ("lidModes", testLidModes),
        ("externalDisplayPauseResume", testExternalDisplayPauseResume),
        ("pausedRemoteStopAndCrash", testPausedRemoteStopAndCrash),
        ("pauseFailure", testPauseFailure),
        ("engageFailures", testEngageFailures),
        ("crossProcessOwnerCrashHung", testCrossProcessOwnerCrashHung),
        ("corruptRecordAndLockHardening", testCorruptRecordAndLockHardening),
        ("batteryPolicy", testBatteryPolicy),
        ("thermal", testThermal),
        ("telemetryDropout", testTelemetryDropout),
        ("safetyStopRestoreFailure", testSafetyStopRestoreFailure),
        ("gestureFilter", testGestureFilter),
        ("idleGesture", testIdleGesture),
        ("controllerAsync", testControllerAsync),
        ("menu", testMenu),
        ("settingsLayout", testSettingsLayout),
        ("churn", testChurn),
    ]
    var failures = 0
    for (name, test) in tests {
        do {
            try test()
            print("PASS: \(name)")
        } catch {
            failures += 1
            print("FAIL: \(name): \(error.localizedDescription)")
        }
    }
    print("\(tests.count - failures)/\(tests.count) tests passed; \(failures) failed.")
    if failures > 0 { exit(1) }
    print("All regression checks passed. No real sleep settings or administrator permissions were changed.")
}

@MainActor
func testRestoreFailureAndMenu() throws {
    let engine = try fresh("restoreFailureAndMenu")
    try check(engine.arm(), "SPI session arms")
    let contender = try child("contender")
    defer { if contender.isRunning { contender.terminate() }; contender.waitUntilExit() }
    contender.waitUntilExit()
    try check(contender.terminationStatus == 0 && engine.armed && TestSystem.flag("spi"), "contender leaves owner unchanged")
    TestSystem.spiRestoreOK = false
    try check(!engine.disarm(), "failed SPI restoration is reported as failure")
    try check(engine.needsRecovery && !engine.armed && StateFile.readDirty() != nil, "failed restoration retains ownership and recovery record")
    let delegate = AppDelegate()
    let menu = NSMenu()
    menu.autoenablesItems = false
    delegate.updateMenu(menu, state: engine.state)
    try check(menu.items.contains { $0.title == "Retry Sleep Restoration" && $0.isEnabled }, "menu exposes recovery action")
    try check(!menu.items.contains { $0.title == "Keep Awake" }, "menu cannot arm over pending restoration")
    TestSystem.spiRestoreOK = true
    try check(engine.disarm(), "restoration can be retried")
    try check(!StateFile.ownsLock && StateFile.readDirty() == nil, "successful restore releases record and lock")
}

@MainActor
func testLidModes() throws {
    let engine = try fresh("lidModes")
    try check(engine.arm(mode: .nextClose), "arm for lid transition")
    TestSystem.lidClosed = true
    engine.updateLid(true)
    TestSystem.lidClosed = false
    engine.refreshSensors()
    engine.updateLid(false)
    try check(!engine.armed && !TestSystem.flag("spi"), "polling before the open notification still disarms")
    try check(engine.arm(mode: .nextClose), "arm for an abandoned lid close")
    engine.tickOnce(now: ProcessInfo.processInfo.systemUptime + 31)
    try check(!engine.armed && StateFile.readDirty() == nil, "an unclosed gesture session ends automatically")
    try check(engine.arm(), "persistent session arms")
    TestSystem.lidClosed = true
    engine.refreshSensors()
    TestSystem.lidClosed = false
    engine.refreshSensors()
    try check(engine.armed, "explicit persistent mode survives lid opening")
    try check(engine.disarm(), "persistent session restores")
}

@MainActor
func testExternalDisplayPauseResume() throws {
    let engine = try fresh("externalDisplayPauseResume")
    TestSystem.externalDisplay = true
    try check(engine.arm() && engine.armed && engine.paused && !TestSystem.flag("spi"), "arming with an external display pauses without changing lid sleep")
    try check(StateFile.ownsLock && StateFile.readDirty() != nil && !IdleHold.held, "paused session keeps the lock and recovery record without an idle assertion")
    let pausedContender = try child("contender")
    defer { if pausedContender.isRunning { pausedContender.terminate() }; pausedContender.waitUntilExit() }
    pausedContender.waitUntilExit()
    try check(pausedContender.terminationStatus == 0 && engine.armed && engine.paused, "contender cannot claim a paused session")
    let pausedRecord = try StateFile.readDirty()
    TestSystem.externalDisplay = false
    engine.tickOnce()
    try check(engine.armed && !engine.paused && TestSystem.flag("spi") && IdleHold.held, "disconnecting the last external display resumes automatically")
    try check(StateFile.ownsLock && StateFile.readDirty()?.session == pausedRecord?.session, "resume keeps the original session record instead of re-acquiring")
    TestSystem.externalDisplay = true
    engine.tickOnce()
    try check(engine.armed && engine.paused && !TestSystem.flag("spi") && !IdleHold.held, "connecting an external display pauses an active session")
    try check(StateFile.ownsLock && StateFile.readDirty() != nil, "pausing an active session keeps ownership")
    try check(engine.turnOff() && !engine.armed && !engine.paused, "Turn Off clears a paused session")
    try check(!StateFile.ownsLock && StateFile.readDirty() == nil, "Turn Off of a paused session restores and releases")
}

@MainActor
func testPausedRemoteStopAndCrash() throws {
    let engine = try fresh("pausedRemoteStopAndCrash")
    TestSystem.externalDisplay = true
    try check(engine.arm() && engine.paused, "arm paused for remote stop")
    try StateFile.requestStop(session: StateFile.readDirty()!.session)
    engine.tickOnce()
    try check(!engine.armed && !StateFile.ownsLock && StateFile.readDirty() == nil, "remote stop ends a paused session")
    let pausedCrash = try child("pausedcrash")
    defer { if pausedCrash.isRunning { pausedCrash.terminate() }; pausedCrash.waitUntilExit() }
    pausedCrash.waitUntilExit()
    try check(pausedCrash.terminationStatus == 0 && StateFile.readDirty() != nil, "crash while paused leaves the recovery record")
    _ = try Watchdog.runOnce()
    try check(StateFile.readDirty() == nil && !TestSystem.flag("spi"), "watchdog clears a dead paused owner's record")
}

@MainActor
func testPauseFailure() throws {
    let engine = try fresh("pauseFailure")
    try check(engine.arm() && !engine.paused, "arm before pause failure")
    TestSystem.spiRestoreOK = false
    TestSystem.externalDisplay = true
    engine.tickOnce()
    try check(!engine.armed && engine.needsRecovery && StateFile.ownsLock && StateFile.readDirty() != nil, "failed pause retains ownership for recovery")
    TestSystem.spiRestoreOK = true
    engine.tickOnce()
    try check(!engine.needsRecovery && !StateFile.ownsLock && !TestSystem.flag("spi"), "failed pause recovers on the next check")
}

@MainActor
func testEngageFailures() throws {
    let engine = try fresh("engageFailures")
    try check(engine.arm(), "arm for reassert failure")
    TestSystem.spiEnableOK = false
    try check(!engine.arm() && !engine.armed && engine.lastError != nil, "failed reassertion cannot report an armed session")
    try check(!TestSystem.flag("spi"), "failed reassertion restores sleep")
    TestSystem.spiEnableOK = true
    TestSystem.idleOK = false
    try check(!engine.arm() && !TestSystem.flag("spi"), "idle assertion failure cancels and restores the session")
    TestSystem.idleOK = true
    TestSystem.launchOK = false
    try check(!engine.arm() && !TestSystem.flag("spi"), "cannot arm without working crash recovery")
    TestSystem.launchOK = true

    TestSystem.spiEnableOK = false
    try check(!engine.arm() && !StateFile.ownsLock && StateFile.readDirty() == nil, "failed lid control leaves no session or recovery record")
    TestSystem.spiEnableOK = true
    try check(engine.arm() && engine.disarm() && engine.lastError == nil, "lid control works again after a failed start")
}

@MainActor
func testCrossProcessOwnerCrashHung() throws {
    _ = try fresh("crossProcessOwnerCrashHung")
    let owner = try child("owner")
    defer { if owner.isRunning { owner.terminate() }; owner.waitUntilExit() }
    try waitForRecord()
    _ = try Watchdog.runOnce()
    try check(TestSystem.flag("spi"), "watchdog leaves a live owner's session unchanged")
    try Watchdog.requestStop()
    owner.waitUntilExit()
    try check(owner.terminationStatus == 0 && StateFile.readDirty() == nil, "remote stop waits for restoration and clears recovery state")
    let crashed = try child("crash")
    defer { if crashed.isRunning { crashed.terminate() }; crashed.waitUntilExit() }
    crashed.waitUntilExit()
    try check(TestSystem.flag("spi"), "crash leaves an owned sleep change")
    _ = try Watchdog.runOnce()
    try check(!TestSystem.flag("spi") && StateFile.readDirty() == nil, "watchdog recovers a dead owner without relying on PID identity")
    let hung = try child("hung")
    defer { if hung.isRunning { hung.terminate() }; hung.waitUntilExit() }
    try waitForRecord()
    try expectError("unresponsive owner returns a timeout without discarding recovery") { try Watchdog.requestStop(timeout: 0.15) }
    try check(StateFile.readDirty() != nil, "timeout preserves the record")
    hung.waitUntilExit()
    _ = try Watchdog.runOnce()
}

@MainActor
func testCorruptRecordAndLockHardening() throws {
    let engine = try fresh("corruptRecordAndLockHardening")
    try "not JSON".write(to: Paths.dirtyURL, atomically: true, encoding: .utf8)
    try expectError("corrupt recovery record is surfaced") { _ = try Watchdog.runOnce() }
    try check(FileManager.default.fileExists(atPath: Paths.dirtyURL.path), "corrupt record is not silently discarded")
    engine.refreshSensors()
    try check(engine.state.error != nil && engine.state.title.contains("recovery record"), "unreadable recovery record is visible in status")
    try FileManager.default.removeItem(at: Paths.dirtyURL)
    engine.refreshSensors()
    try check(engine.state.error == nil, "recovery read error clears after the record is repaired")
    _ = try StateFile.acquireLock()
    StateFile.releaseLock()
    let lock = Paths.supportDir.appendingPathComponent("owner.lock")
    try FileManager.default.removeItem(at: lock)
    try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: Paths.dirtyURL)
    try expectError("symlink session locks are rejected") { _ = try StateFile.acquireLock() }
    try FileManager.default.removeItem(at: lock)
    var info = stat()
    try check(lstat(Paths.supportDir.path, &info) == 0 && info.st_mode & 0o777 == 0o700, "session directory is private to the user")
}

@MainActor
func testBatteryPolicy() throws {
    let engine = try fresh("batteryPolicy")
    // Safety policies exercise the real engine with deterministic telemetry.
    Defaults.batteryFloor = 20
    Battery.value = BatteryReading(percent: 0, onBattery: true)
    let emptyBatteryWrites = TestSystem.spiWrites
    try check(!engine.arm() && TestSystem.spiWrites == emptyBatteryWrites, "a reported empty battery blocks a protected start before changing sleep settings")
    Battery.value = BatteryReading(percent: 0, onBattery: false)
    try check(engine.arm(), "a reported empty battery still permits AC-powered work")
    Battery.value = BatteryReading(percent: 0, onBattery: true)
    engine.tickOnce()
    try check(!engine.armed && !TestSystem.flag("spi"), "unplugging at a reported zero percent ends a protected session")
    Defaults.batteryFloor = 0
    try check(engine.arm(), "turning battery protection off also disables the zero-percent check")
    try check(engine.disarm(), "unprotected zero-percent session restores normally")
    Defaults.batteryFloor = 20
    Battery.value = BatteryReading(percent: 1, onBattery: true)
    try check(engine.arm(), "a deliberate start above zero remains allowed")
    engine.tickOnce()
    try check(engine.armed, "a deliberate one-percent start survives an unchanged reading")
    Battery.value = BatteryReading(percent: 0, onBattery: true)
    engine.tickOnce()
    try check(!engine.armed && !TestSystem.flag("spi"), "a low-battery session ends when the reported charge reaches zero")
    Battery.value = BatteryReading(percent: 20, onBattery: true)
    try check(engine.arm(), "a deliberate arm at the battery floor is allowed")
    engine.tickOnce()
    try check(engine.armed, "a session deliberately started below the floor is not immediately cancelled")
    Battery.value = BatteryReading(percent: 19, onBattery: true)
    engine.tickOnce()
    try check(!engine.armed && !TestSystem.flag("spi"), "a deliberate low-battery session stops when charge falls further")
    Battery.value = BatteryReading(percent: 5, onBattery: false)
    try check(engine.arm(), "low charge does not prevent an AC-powered session")
    TestSystem.lidClosed = true
    engine.refreshSensors()
    Battery.value = BatteryReading(percent: 5, onBattery: true)
    let sleepCalls = PowerSleep.calls
    engine.tickOnce()
    try check(!engine.armed && engine.notice != nil && PowerSleep.calls == sleepCalls + 1, "unplugging below the floor restores and requests sleep with lid closed")
    Battery.value = BatteryReading(percent: 80, onBattery: true)
    try check(engine.arm(), "battery session can restart after charge recovers")
}

@MainActor
func testThermal() throws {
    let engine = try fresh("thermal")
    Defaults.batteryFloor = 20
    Battery.value = BatteryReading(percent: 80, onBattery: true)
    TestSystem.lidClosed = true
    guard engine.arm() else { throw TestFailure("thermal setup failed") }
    Thermals.state = .serious
    engine.tickOnce()
    try check(!engine.armed && !TestSystem.flag("spi"), "serious thermal pressure restores sleep")
    try check(!engine.arm(), "thermal protection blocks re-arming until cooled")
    Thermals.state = .nominal
    TestSystem.lidClosed = false
    engine.refreshSensors()
    try check(engine.arm(), "session resumes only after a new explicit arm")
    let openSleepCalls = PowerSleep.calls
    Thermals.state = .critical
    engine.tickOnce()
    try check(!engine.armed && PowerSleep.calls == openSleepCalls, "thermal protection does not force an open laptop to sleep")
}

@MainActor
func testTelemetryDropout() throws {
    let engine = try fresh("telemetryDropout")
    Defaults.batteryFloor = 20
    Battery.value = BatteryReading(percent: 80, onBattery: true)
    try check(engine.arm(), "arm before telemetry dropout")
    Battery.value = BatteryReading(percent: nil, onBattery: nil)
    engine.tickOnce(now: 100)
    engine.tickOnce(now: 114)
    try check(engine.armed, "brief battery telemetry loss does not interrupt work")
    engine.tickOnce(now: 115)
    try check(!engine.armed && engine.notice != nil, "persistent telemetry loss fails toward sleep")
    try check(!engine.arm(), "unknown battery status blocks a new protected session")
    Defaults.batteryFloor = 0
    try check(engine.arm(), "battery protection can be explicitly disabled")
    try check(engine.disarm(), "unprotected session restores normally")
}

@MainActor
func testSafetyStopRestoreFailure() throws {
    let engine = try fresh("safetyStopRestoreFailure")
    Defaults.batteryFloor = 20
    Battery.value = BatteryReading(percent: 80, onBattery: true)
    try check(engine.arm(), "arm before safety restore failure")
    TestSystem.lidClosed = true
    engine.refreshSensors()
    TestSystem.spiRestoreOK = false
    Battery.value = BatteryReading(percent: 10, onBattery: true)
    engine.tickOnce()
    try check(engine.needsRecovery && StateFile.readDirty() != nil, "safety stop retains failed backend recovery")
    TestSystem.spiRestoreOK = true
    PowerSleep.succeeds = false
    TestSystem.spiEnableOK = false
    engine.tickOnce()
    try check(engine.needsRecovery && engine.lastError != nil && !TestSystem.flag("spi") && !StateFile.ownsLock && StateFile.readDirty() == nil, "refused sleep with a failed lid re-check stays visible and retryable")
    TestSystem.spiEnableOK = true
    let writesBefore = TestSystem.spiWrites
    engine.tickOnce()
    try check(!engine.needsRecovery && engine.lastError == nil && TestSystem.spiWrites == writesBefore + 2 && !TestSystem.flag("spi") && StateFile.readDirty() == nil && !StateFile.ownsLock, "refused sleep request falls back to the recorded kernel lid re-check")
    PowerSleep.succeeds = true
    TestSystem.externalDisplay = true
    try check(engine.arm() && engine.paused, "arm paused before thermal stop")
    Thermals.state = .critical
    let pausedSleepCalls = PowerSleep.calls
    engine.tickOnce()
    try check(!engine.armed && !engine.needsRecovery && PowerSleep.calls == pausedSleepCalls && !StateFile.ownsLock, "safety stop of a paused session releases without forcing sleep")
}

@MainActor
func testGestureFilter() throws {
    _ = try fresh("gestureFilter")
    var motion = ClosingMotion()
    try check(!motion.sample(option: true, angle: 110, now: 0), "gesture starts without arming")
    try check(!motion.sample(option: true, angle: 106, now: 0.025), "brief Option glitch cannot arm")
    try check(!motion.sample(option: true, angle: 102, now: 0.05), "closing movement alone cannot bypass the steady hold")
    _ = motion.sample(option: false, angle: nil, now: 0.06)
    _ = motion.sample(option: true, angle: 110, now: 1)
    _ = motion.sample(option: true, angle: 106, now: 1.1)
    try check(motion.sample(option: true, angle: 102, now: 1.2), "steady Option and closing motion arm")
    try check(!motion.sample(option: true, angle: 98, now: 1.3), "one hold produces only one arm")
    motion.reset()
    _ = motion.sample(option: true, angle: 100, now: 0)
    _ = motion.sample(option: true, angle: 110, now: 0.1)
    try check(!motion.sample(option: true, angle: 120, now: 0.2), "opening motion never arms")
    motion.reset()
    _ = motion.sample(option: true, angle: 100, now: 0)
    _ = motion.sample(option: true, angle: nil, now: 0.1)
    try check(!motion.sample(option: true, angle: 90, now: 0.2), "sensor dropout discards stale gesture motion")
    _ = motion.sample(option: true, angle: 86, now: 0.3)
    try check(motion.sample(option: true, angle: 82, now: 0.4), "gesture recovers after fresh sensor samples")
    motion.reset()
    _ = motion.sample(option: true, angle: 160, now: 0)
    try check(!motion.sample(option: true, angle: 10, now: 0.2), "implausible sensor jump cannot arm")
}

@MainActor
func testIdleGesture() throws {
    _ = try fresh("idleGesture")
    let idleGesture = CloseGesture(isOptionHeld: { false })
    let readsBefore = LidAngle.reads
    defer { idleGesture.stop() }
    idleGesture.start()
    RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    try check(LidAngle.reads == readsBefore, "idle gesture monitoring never reads the hinge sensor")
}

@MainActor
func testControllerAsync() throws {
    let engine = try fresh("controllerAsync")
    Defaults.batteryFloor = 20
    // A slow command must not prevent the main run loop from handling UI work.
    let controller = SessionController(engine: engine)
    defer {
        var done = false
        controller.perform(.refresh) { _ in done = true }
        let deadline = Date().addingTimeInterval(10)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        if !done {
            print("FAIL: controllerAsync: controller cleanup timed out")
            exit(1)
        }
    }
    TestSystem.commandDelay = 0.08
    var completed = false
    var mainResponded = false
    controller.perform(.arm(.persistent)) { ok in completed = ok }
    try check(controller.busy != nil, "asynchronous control exposes a busy state immediately")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { mainResponded = !completed }
    let operationDeadline = Date().addingTimeInterval(10)
    while !completed && Date() < operationDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    try check(completed && mainResponded, "slow sleep commands leave the main thread responsive")
    var stopped = false
    controller.perform(.turnOff) { ok in stopped = ok }
    while !stopped && Date() < operationDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    try check(stopped && !controller.state.armed, "asynchronous stop publishes the restored state")
    TestSystem.commandDelay = 0
    var refreshed = false
    var queuedStop = false
    controller.perform(.arm(.persistent))
    controller.perform(.refresh) { _ in refreshed = true }
    controller.perform(.turnOff) { ok in queuedStop = ok }
    let queueDeadline = Date().addingTimeInterval(10)
    while !queuedStop && Date() < queueDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    try check(refreshed && queuedStop && !controller.state.armed, "queued status and stop requests complete in order")
    var lidEventsDone = false
    controller.perform(.arm(.nextClose))
    controller.perform(.lidChanged(true))
    controller.perform(.lidChanged(false)) { _ in lidEventsDone = true }
    let lidEventDeadline = Date().addingTimeInterval(10)
    while !lidEventsDone && Date() < lidEventDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    try check(lidEventsDone && !controller.state.armed, "queued close and open events end the session even when the latest lid sample is open")
}

@MainActor
func testMenu() throws {
    let engine = try fresh("menu")
    let controller = SessionController(engine: engine)
    let delegate = AppDelegate()
    let compact = NSMenu()
    compact.autoenablesItems = false
    delegate.updateMenu(compact, state: controller.state)
    try check(compact.items.filter { $0.title == "Keep Awake" || $0.title == "Turn Off" }.count == 1, "menu exposes one primary action")
    delegate.updateMenu(compact, state: controller.state, busy: "Restoring sleep…")
    try check(compact.items.first?.isEnabled == false, "busy menu cannot submit duplicate actions")
}

@MainActor
func testSettingsLayout() throws {
    let engine = try fresh("settingsLayout")
    Defaults.batteryFloor = 20
    let controller = SessionController(engine: engine)
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let settings = SettingsWindow(controller: controller)
    let content = settings.window!.contentView!
    content.layoutSubtreeIfNeeded()
    let stack = content.subviews.first as! NSStackView
    for view in stack.arrangedSubviews {
        let frame = view.convert(view.bounds, to: content)
        try check(content.bounds.contains(frame) && frame.height > 0, "Settings control fits within the window: \(type(of: view))")
    }
}

@MainActor
func testChurn() throws {
    _ = try fresh("churn")
    let churn = try child("churn")
    defer { if churn.isRunning { churn.terminate() }; churn.waitUntilExit() }
    while churn.isRunning { _ = try StateFile.readDirty() }
    churn.waitUntilExit()
    try check(churn.terminationStatus == 0, "concurrent record replacement and removal remain readable")
}

try MainActor.assumeIsolated { try runTests() }
