import AppKit
import Darwin
import Foundation

setbuf(stdout, nil)

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
    guard try condition() else { fatalError(message) }
    print("PASS: \(message)")
}
func expectError(_ message: String, _ action: () throws -> Void) {
    do { try action(); fatalError(message) }
    catch { print("PASS: \(message)") }
}
func child(_ mode: String) throws -> Process {
    TestSystem.setFlag("ready", false)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = [CommandLine.arguments[1], mode]
    try process.run()
    return process
}
func waitForRecord() throws {
    let deadline = Date().addingTimeInterval(5)
    while !TestSystem.flag("ready"), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    try check(TestSystem.flag("ready") && StateFile.readDirty() != nil, "child finished arming and recorded its session")
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
    check(!engine.armed, "remote stop disarmed the owning process")
    Thread.sleep(forTimeInterval: 0.1)
    engine.tickOnce()
    check(!TestSystem.flag("spi"), "owner does not re-arm after remote stop")
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
    check(!engine.arm(), "a second process cannot claim an active session")
    check(!StateFile.ownsLock, "failed contender does not own the session lock")
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

check(engine.arm(), "SPI session arms")
let contender = try child("contender")
contender.waitUntilExit()
check(contender.terminationStatus == 0 && engine.armed && TestSystem.flag("spi"), "contender leaves owner unchanged")
TestSystem.spiRestoreOK = false
check(!engine.disarm(), "failed SPI restoration is reported as failure")
try check(engine.needsRecovery && !engine.armed && StateFile.readDirty() != nil, "failed restoration retains ownership and recovery record")
let delegate = AppDelegate()
let menu = NSMenu()
menu.autoenablesItems = false
delegate.updateMenu(menu, state: engine.state)
check(menu.items.contains { $0.title == "Retry Sleep Restoration" && $0.isEnabled }, "menu exposes recovery action")
check(!menu.items.contains { $0.title == "Keep Awake" }, "menu cannot arm over pending restoration")
TestSystem.spiRestoreOK = true
check(engine.disarm(), "restoration can be retried")
try check(!StateFile.ownsLock && StateFile.readDirty() == nil, "successful restore releases record and lock")

check(engine.arm(mode: .nextClose), "arm for lid transition")
TestSystem.lidClosed = true
engine.updateLid(true)
TestSystem.lidClosed = false
engine.refreshSensors()
engine.updateLid(false)
check(!engine.armed && !TestSystem.flag("spi"), "polling before the open notification still disarms")
check(engine.arm(mode: .nextClose), "arm for an abandoned lid close")
engine.tickOnce(now: ProcessInfo.processInfo.systemUptime + 31)
try check(!engine.armed && StateFile.readDirty() == nil, "an unclosed gesture session ends automatically")
check(engine.arm(), "persistent session arms")
TestSystem.lidClosed = true
engine.refreshSensors()
TestSystem.lidClosed = false
engine.refreshSensors()
check(engine.armed, "explicit persistent mode survives lid opening")
check(engine.disarm(), "persistent session restores")

TestSystem.externalDisplay = true
check(engine.arm() && engine.armed && engine.paused && !TestSystem.flag("spi"), "arming with an external display pauses without changing lid sleep")
try check(StateFile.ownsLock && StateFile.readDirty() != nil && !IdleHold.held, "paused session keeps the lock and recovery record without an idle assertion")
let pausedContender = try child("contender")
pausedContender.waitUntilExit()
check(pausedContender.terminationStatus == 0 && engine.armed && engine.paused, "contender cannot claim a paused session")
let pausedRecord = try StateFile.readDirty()
TestSystem.externalDisplay = false
engine.tickOnce()
check(engine.armed && !engine.paused && TestSystem.flag("spi") && IdleHold.held, "disconnecting the last external display resumes automatically")
try check(StateFile.ownsLock && StateFile.readDirty()?.session == pausedRecord?.session, "resume keeps the original session record instead of re-acquiring")
TestSystem.externalDisplay = true
engine.tickOnce()
check(engine.armed && engine.paused && !TestSystem.flag("spi") && !IdleHold.held, "connecting an external display pauses an active session")
try check(StateFile.ownsLock && StateFile.readDirty() != nil, "pausing an active session keeps ownership")
check(engine.turnOff() && !engine.armed && !engine.paused, "Turn Off clears a paused session")
try check(!StateFile.ownsLock && StateFile.readDirty() == nil, "Turn Off of a paused session restores and releases")
check(engine.arm() && engine.paused, "arm paused for remote stop")
try StateFile.requestStop(session: StateFile.readDirty()!.session)
engine.tickOnce()
try check(!engine.armed && !StateFile.ownsLock && StateFile.readDirty() == nil, "remote stop ends a paused session")
let pausedCrash = try child("pausedcrash")
pausedCrash.waitUntilExit()
try check(pausedCrash.terminationStatus == 0 && StateFile.readDirty() != nil, "crash while paused leaves the recovery record")
_ = try Watchdog.runOnce()
try check(StateFile.readDirty() == nil && !TestSystem.flag("spi"), "watchdog clears a dead paused owner's record")
TestSystem.externalDisplay = false
check(engine.arm() && !engine.paused, "arm before pause failure")
TestSystem.spiRestoreOK = false
TestSystem.externalDisplay = true
engine.tickOnce()
try check(!engine.armed && engine.needsRecovery && StateFile.ownsLock && StateFile.readDirty() != nil, "failed pause retains ownership for recovery")
TestSystem.spiRestoreOK = true
engine.tickOnce()
check(!engine.needsRecovery && !StateFile.ownsLock && !TestSystem.flag("spi"), "failed pause recovers on the next check")
TestSystem.externalDisplay = false

check(engine.arm(), "arm for reassert failure")
TestSystem.spiEnableOK = false
check(!engine.arm() && !engine.armed && engine.lastError != nil, "failed reassertion cannot report an armed session")
check(!TestSystem.flag("spi"), "failed reassertion restores sleep")
TestSystem.spiEnableOK = true
TestSystem.idleOK = false
check(!engine.arm() && !TestSystem.flag("spi"), "idle assertion failure cancels and restores the session")
TestSystem.idleOK = true
TestSystem.launchOK = false
check(!engine.arm() && !TestSystem.flag("spi"), "cannot arm without working crash recovery")
TestSystem.launchOK = true

TestSystem.spiEnableOK = false
try check(!engine.arm() && !StateFile.ownsLock && StateFile.readDirty() == nil, "failed lid control leaves no session or recovery record")
TestSystem.spiEnableOK = true
check(engine.arm() && engine.disarm() && engine.lastError == nil, "lid control works again after a failed start")

let owner = try child("owner")
try waitForRecord()
_ = try Watchdog.runOnce()
check(TestSystem.flag("spi"), "watchdog leaves a live owner's session unchanged")
try Watchdog.requestStop()
owner.waitUntilExit()
try check(owner.terminationStatus == 0 && StateFile.readDirty() == nil, "remote stop waits for restoration and clears recovery state")
let crashed = try child("crash")
crashed.waitUntilExit()
check(TestSystem.flag("spi"), "crash leaves an owned sleep change")
_ = try Watchdog.runOnce()
try check(!TestSystem.flag("spi") && StateFile.readDirty() == nil, "watchdog recovers a dead owner without relying on PID identity")
let hung = try child("hung")
try waitForRecord()
expectError("unresponsive owner returns a timeout without discarding recovery") { try Watchdog.requestStop(timeout: 0.15) }
try check(StateFile.readDirty() != nil, "timeout preserves the record")
hung.waitUntilExit()
_ = try Watchdog.runOnce()

try "not JSON".write(to: Paths.dirtyURL, atomically: true, encoding: .utf8)
expectError("corrupt recovery record is surfaced") { _ = try Watchdog.runOnce() }
check(FileManager.default.fileExists(atPath: Paths.dirtyURL.path), "corrupt record is not silently discarded")
engine.refreshSensors()
check(engine.state.error != nil && engine.state.title.contains("recovery record"), "unreadable recovery record is visible in status")
try FileManager.default.removeItem(at: Paths.dirtyURL)
engine.refreshSensors()
check(engine.state.error == nil, "recovery read error clears after the record is repaired")
let lock = Paths.supportDir.appendingPathComponent("owner.lock")
try FileManager.default.removeItem(at: lock)
try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: Paths.dirtyURL)
expectError("symlink session locks are rejected") { _ = try StateFile.acquireLock() }
try FileManager.default.removeItem(at: lock)
var info = stat()
check(lstat(Paths.supportDir.path, &info) == 0 && info.st_mode & 0o777 == 0o700, "session directory is private to the user")

// Safety policies exercise the real engine with deterministic telemetry.
Defaults.batteryFloor = 20
Battery.value = BatteryReading(percent: 0, onBattery: true)
let emptyBatteryWrites = TestSystem.spiWrites
check(!engine.arm() && TestSystem.spiWrites == emptyBatteryWrites, "a reported empty battery blocks a protected start before changing sleep settings")
Battery.value = BatteryReading(percent: 0, onBattery: false)
check(engine.arm(), "a reported empty battery still permits AC-powered work")
Battery.value = BatteryReading(percent: 0, onBattery: true)
engine.tickOnce()
check(!engine.armed && !TestSystem.flag("spi"), "unplugging at a reported zero percent ends a protected session")
Defaults.batteryFloor = 0
check(engine.arm(), "turning battery protection off also disables the zero-percent check")
check(engine.disarm(), "unprotected zero-percent session restores normally")
Defaults.batteryFloor = 20
Battery.value = BatteryReading(percent: 1, onBattery: true)
check(engine.arm(), "a deliberate start above zero remains allowed")
engine.tickOnce()
check(engine.armed, "a deliberate one-percent start survives an unchanged reading")
Battery.value = BatteryReading(percent: 0, onBattery: true)
engine.tickOnce()
check(!engine.armed && !TestSystem.flag("spi"), "a low-battery session ends when the reported charge reaches zero")
Battery.value = BatteryReading(percent: 20, onBattery: true)
check(engine.arm(), "a deliberate arm at the battery floor is allowed")
engine.tickOnce()
check(engine.armed, "a session deliberately started below the floor is not immediately cancelled")
Battery.value = BatteryReading(percent: 19, onBattery: true)
engine.tickOnce()
check(!engine.armed && !TestSystem.flag("spi"), "a deliberate low-battery session stops when charge falls further")
Battery.value = BatteryReading(percent: 5, onBattery: false)
check(engine.arm(), "low charge does not prevent an AC-powered session")
TestSystem.lidClosed = true
engine.refreshSensors()
Battery.value = BatteryReading(percent: 5, onBattery: true)
let sleepCalls = PowerSleep.calls
engine.tickOnce()
check(!engine.armed && engine.notice != nil && PowerSleep.calls == sleepCalls + 1, "unplugging below the floor restores and requests sleep with lid closed")
Battery.value = BatteryReading(percent: 80, onBattery: true)
check(engine.arm(), "battery session can restart after charge recovers")
Thermals.state = .serious
engine.tickOnce()
check(!engine.armed && !TestSystem.flag("spi"), "serious thermal pressure restores sleep")
check(!engine.arm(), "thermal protection blocks re-arming until cooled")
Thermals.state = .nominal
TestSystem.lidClosed = false
engine.refreshSensors()
check(engine.arm(), "session resumes only after a new explicit arm")
let openSleepCalls = PowerSleep.calls
Thermals.state = .critical
engine.tickOnce()
check(!engine.armed && PowerSleep.calls == openSleepCalls, "thermal protection does not force an open laptop to sleep")
Thermals.state = .nominal
check(engine.arm(), "arm before telemetry dropout")
Battery.value = BatteryReading(percent: nil, onBattery: nil)
engine.tickOnce(now: 100)
engine.tickOnce(now: 114)
check(engine.armed, "brief battery telemetry loss does not interrupt work")
engine.tickOnce(now: 115)
check(!engine.armed && engine.notice != nil, "persistent telemetry loss fails toward sleep")
check(!engine.arm(), "unknown battery status blocks a new protected session")
Defaults.batteryFloor = 0
check(engine.arm(), "battery protection can be explicitly disabled")
check(engine.disarm(), "unprotected session restores normally")
Defaults.batteryFloor = 20
Battery.value = BatteryReading(percent: 80, onBattery: true)
check(engine.arm(), "arm before safety restore failure")
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
check(engine.arm() && engine.paused, "arm paused before thermal stop")
Thermals.state = .critical
let pausedSleepCalls = PowerSleep.calls
engine.tickOnce()
check(!engine.armed && !engine.needsRecovery && PowerSleep.calls == pausedSleepCalls && !StateFile.ownsLock, "safety stop of a paused session releases without forcing sleep")
Thermals.state = .nominal
TestSystem.externalDisplay = false
TestSystem.lidClosed = false
Battery.value = BatteryReading(percent: 100, onBattery: false)
engine.refreshSensors()

var motion = ClosingMotion()
check(!motion.sample(option: true, angle: 110, now: 0), "gesture starts without arming")
check(!motion.sample(option: true, angle: 106, now: 0.025), "brief Option glitch cannot arm")
check(!motion.sample(option: true, angle: 102, now: 0.05), "closing movement alone cannot bypass the steady hold")
_ = motion.sample(option: false, angle: nil, now: 0.06)
_ = motion.sample(option: true, angle: 110, now: 1)
_ = motion.sample(option: true, angle: 106, now: 1.1)
check(motion.sample(option: true, angle: 102, now: 1.2), "steady Option and closing motion arm")
check(!motion.sample(option: true, angle: 98, now: 1.3), "one hold produces only one arm")
motion.reset()
_ = motion.sample(option: true, angle: 100, now: 0)
_ = motion.sample(option: true, angle: 110, now: 0.1)
check(!motion.sample(option: true, angle: 120, now: 0.2), "opening motion never arms")
motion.reset()
_ = motion.sample(option: true, angle: 100, now: 0)
_ = motion.sample(option: true, angle: nil, now: 0.1)
check(!motion.sample(option: true, angle: 90, now: 0.2), "sensor dropout discards stale gesture motion")
_ = motion.sample(option: true, angle: 86, now: 0.3)
check(motion.sample(option: true, angle: 82, now: 0.4), "gesture recovers after fresh sensor samples")
motion.reset()
_ = motion.sample(option: true, angle: 160, now: 0)
check(!motion.sample(option: true, angle: 10, now: 0.2), "implausible sensor jump cannot arm")
let idleGesture = CloseGesture(isOptionHeld: { false })
let readsBefore = LidAngle.reads
idleGesture.start()
RunLoop.main.run(until: Date().addingTimeInterval(0.35))
check(LidAngle.reads == readsBefore, "idle gesture monitoring never reads the hinge sensor")
idleGesture.stop()

// A slow command must not prevent the main run loop from handling UI work.
let controller = SessionController(engine: engine)
TestSystem.commandDelay = 0.08
var completed = false
var mainResponded = false
controller.perform(.arm(.persistent)) { ok in completed = ok }
check(controller.busy != nil, "asynchronous control exposes a busy state immediately")
DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { mainResponded = !completed }
let operationDeadline = Date().addingTimeInterval(10)
while !completed && Date() < operationDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
check(completed && mainResponded, "slow sleep commands leave the main thread responsive")
var stopped = false
controller.perform(.turnOff) { ok in stopped = ok }
while !stopped && Date() < operationDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
check(stopped && !controller.state.armed, "asynchronous stop publishes the restored state")
TestSystem.commandDelay = 0
var refreshed = false
var queuedStop = false
controller.perform(.arm(.persistent))
controller.perform(.refresh) { _ in refreshed = true }
controller.perform(.turnOff) { ok in queuedStop = ok }
let queueDeadline = Date().addingTimeInterval(10)
while !queuedStop && Date() < queueDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
check(refreshed && queuedStop && !controller.state.armed, "queued status and stop requests complete in order")
var lidEventsDone = false
controller.perform(.arm(.nextClose))
controller.perform(.lidChanged(true))
controller.perform(.lidChanged(false)) { _ in lidEventsDone = true }
let lidEventDeadline = Date().addingTimeInterval(10)
while !lidEventsDone && Date() < lidEventDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
check(lidEventsDone && !controller.state.armed, "queued close and open events end the session even when the latest lid sample is open")
let compact = NSMenu()
compact.autoenablesItems = false
delegate.updateMenu(compact, state: controller.state)
check(compact.items.filter { $0.title == "Keep Awake" || $0.title == "Turn Off" }.count == 1, "menu exposes one primary action")
delegate.updateMenu(compact, state: controller.state, busy: "Restoring sleep…")
check(compact.items.first?.isEnabled == false, "busy menu cannot submit duplicate actions")

do {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let settings = SettingsWindow(controller: controller)
    let content = settings.window!.contentView!
    content.layoutSubtreeIfNeeded()
    let stack = content.subviews.first as! NSStackView
    for view in stack.arrangedSubviews {
        let frame = view.convert(view.bounds, to: content)
        check(content.bounds.contains(frame) && frame.height > 0, "Settings control fits within the window: \(type(of: view))")
    }
}

let churn = try child("churn")
while churn.isRunning { _ = try StateFile.readDirty() }
churn.waitUntilExit()
check(churn.terminationStatus == 0, "concurrent record replacement and removal remain readable")

print("All regression checks passed. No real sleep settings or administrator permissions were changed.")
}

try MainActor.assumeIsolated { try runTests() }
