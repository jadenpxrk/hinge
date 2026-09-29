import Foundation

final class StayEngine {
    private let spi = ClamshellSPI()
    private var session = UUID()

    private enum Phase { case idle, active, paused }
    private var phase = Phase.idle
    var armed: Bool { phase != .idle }
    var paused: Bool { phase == .paused }
    private var armMode: ArmMode = .persistent
    private(set) var lastError: String?
    private var recoveryReadError: String?
    private(set) var lidClosed = false
    private(set) var lastSleepDisabled: Bool?
    private(set) var anotherSession = false
    var needsRecovery: Bool { (StateFile.ownsLock && !armed) || sleepPending }
    private var sleepPending = false
    private var missingBatterySince: TimeInterval?
    /// Set only for a deliberate start at or below the battery floor: stop at or below this charge instead of the floor.
    private var batteryStopAt: Int?
    private var awaitingCloseSince: TimeInterval?
    private(set) var notice: String?

    init() {}

    func updateLid(_ closed: Bool) {
        let opened = lidClosed && !closed
        lidClosed = closed
        if closed, armed, armMode == .nextClose { awaitingCloseSince = nil }
        if opened, armed, armMode == .nextClose {
            _ = disarm(reason: "lid opened")
        }
    }

    func refreshSensors() {
        if let closed = IOPM.snapshot().lidClosed { updateLid(closed) }
        lastSleepDisabled = IOPM.snapshot().sleepDisabled
        guard !StateFile.ownsLock else { anotherSession = false; recoveryReadError = nil; return }
        do {
            anotherSession = try StateFile.readDirty() != nil
            recoveryReadError = nil
        } catch {
            anotherSession = false
            recoveryReadError = error.localizedDescription
        }
    }

    @discardableResult
    func arm(mode: ArmMode = .persistent) -> Bool {
        refreshSensors()
        if armed { return paused || reassert() }
        armMode = mode
        notice = nil
        if needsRecovery, !disarm(reason: "retry recovery") { return false }
        if let reason = safetyReason(now: ProcessInfo.processInfo.systemUptime, arming: true) {
            lastError = reason
            return false
        }
        lastError = nil
        do {
            guard try StateFile.acquireLock() else {
                throw HingeError(message: "Another Hinge session is active. Turn it off before starting this one.")
            }
            try Watchdog.restoreOwned()
            try Watchdog.installLaunchAgent()
            session = UUID()
            try StateFile.markDirty(session: session)
            phase = .active
            awaitingCloseSince = mode == .nextClose && !lidClosed ? ProcessInfo.processInfo.systemUptime : nil
            if Displays.hasExternal {
                phase = .paused
                notice = "Paused while an external display is connected"
            } else {
                try engage()
            }
            refreshSensors()
            return true
        } catch {
            fail(error.localizedDescription, reason: "arm failed")
            return false
        }
    }

    @discardableResult
    func disarm(reason: String = "user") -> Bool {
        phase = .idle
        awaitingCloseSince = nil
        batteryStopAt = nil
        IdleHold.release()
        guard StateFile.ownsLock else { return finishSafetySleep() }
        do {
            try Watchdog.restoreOwned()
            StateFile.releaseLock()
            lastError = nil
            lastSleepDisabled = IOPM.snapshot().sleepDisabled
            fputs("Hinge restored sleep (\(reason))\n", stderr)
            return finishSafetySleep()
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func restoreBestEffort() {
        // Never restore another process's session from an atexit handler.
        if StateFile.ownsLock || sleepPending { _ = disarm(reason: "exit") }
    }

    /// Explicit controls may stop a session started by another Hinge process.
    @discardableResult
    func turnOff() -> Bool {
        if armed || StateFile.ownsLock || sleepPending { return disarm() }
        do {
            try Watchdog.requestStop()
            lastError = nil
            refreshSensors()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func toggle() -> Bool {
        refreshSensors()
        if armed || needsRecovery || anotherSession { return turnOff() }
        return arm(mode: .persistent)
    }

    var statusTitle: String {
        if needsRecovery { return "Sleep restoration needs attention" }
        if recoveryReadError != nil { return "Sleep recovery record needs attention" }
        if lastError != nil { return "Hinge needs attention" }
        if paused { return "Paused while an external display is connected" }
        if armed { return armMode == .persistent ? "Keeping awake until turned off" : "Keeping awake until the lid opens" }
        if let notice { return notice }
        if anotherSession { return "Another Hinge session needs to be turned off" }
        if lastSleepDisabled == true { return "Sleep is disabled outside Hinge" }
        return "Normal lid sleep"
    }

    var statusLine: String {
        let snap = IOPM.snapshot()
        let lid = snap.lidClosed.map { $0 ? "closed" : "open" } ?? "unknown"
        let causes = snap.clamshellCausesSleep.map { $0 ? "yes" : "no" } ?? "unknown"
        let sd = lastSleepDisabled.map { $0 ? "1" : "0" } ?? "unknown"
        var line = "armed=\(armed) paused=\(paused) mode=\(armMode.rawValue) recoveryPending=\(needsRecovery) lid=\(lid) AppleClamshellCausesSleep=\(causes) SleepDisabled=\(sd)"
        if let error = lastError ?? recoveryReadError { line += " error=\(error)" }
        return line
    }

    /// Applies the recorded change. The caller holds the lock and the recovery record.
    private func engage() throws {
        guard spi.setLidSleepDisabled(true) else {
            // The bit never changed, so recovery has nothing to undo.
            try StateFile.clearDirty()
            throw HingeError(message: "This Mac could not enable lid control.")
        }
        guard IdleHold.take() else {
            throw HingeError(message: "Could not prevent idle sleep. The awake session was cancelled.")
        }
    }

    /// Ends the session after a failure. If restoration itself fails, ownership and the record stay for recovery.
    private func fail(_ message: String, reason: String) {
        let restored = disarm(reason: reason)
        lastError = restored ? message : "\(message) \(lastError ?? "")"
    }

    /// Lid sleep returns to macOS while a display is attached. The lock, record and LaunchAgent stay,
    /// so no other Hinge can claim the session and a crash while paused is still recovered.
    private func pause() {
        IdleHold.release()
        guard spi.setLidSleepDisabled(false) else {
            _ = disarm(reason: "external display connected")
            return
        }
        phase = .paused
        notice = "Paused while an external display is connected"
    }

    private func resume() {
        phase = .active
        notice = nil
        do { try engage() } catch { fail(error.localizedDescription, reason: "resume failed") }
    }

    @discardableResult
    private func reassert() -> Bool {
        guard armed, !paused else { return false }
        guard spi.setLidSleepDisabled(true) else {
            let message = "Hinge lost the ability to keep this Mac awake."
            let restored = disarm(reason: "keep-awake failed")
            lastError = restored ? "\(message) Normal lid sleep was restored." : "\(message) \(lastError ?? "")"
            return false
        }
        return true
    }

    func tickOnce(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if StateFile.ownsLock, StateFile.stopRequested(session: session) {
            _ = disarm(reason: "remote request")
        } else if needsRecovery {
            _ = disarm(reason: "retry recovery")
        }
        refreshSensors()
        guard armed else { return }
        if let awaitingCloseSince, !lidClosed, now - awaitingCloseSince >= 30 {
            notice = "Stopped because the lid was not closed"
            _ = disarm(reason: "lid close abandoned")
            return
        }
        if Displays.hasExternal, !paused { pause(); return }
        if let reason = safetyReason(now: now, arming: false) {
            notice = reason
            // While paused Hinge is not holding the Mac awake, so there is nothing to fail closed.
            sleepPending = !paused
            _ = disarm(reason: "safety stop")
        } else if paused {
            if !Displays.hasExternal { resume() }
        } else {
            reassert()
        }
    }

    private func safetyReason(now: TimeInterval, arming: Bool) -> String? {
        if Thermals.state == .serious || Thermals.state == .critical {
            return "Mac is too warm. Wait for it to cool before keeping it awake."
        }
        let floor = Defaults.batteryFloor
        guard floor > 0 else { missingBatterySince = nil; return nil }
        let battery = Battery.read()
        if battery.onBattery == false {
            missingBatterySince = nil
            batteryStopAt = nil
            return nil
        }
        guard battery.onBattery == true, let percent = battery.percent else {
            if missingBatterySince == nil { missingBatterySince = now }
            if arming || now - (missingBatterySince ?? now) >= 15 {
                return "Battery status is unavailable. Awake mode is off for battery protection."
            }
            return nil
        }
        missingBatterySince = nil
        if percent == 0 { return "Battery reports 0%. Awake mode is off for battery protection." }
        if arming || percent > floor {
            batteryStopAt = percent > floor ? nil : percent - 1
            return nil
        }
        return percent <= batteryStopAt ?? floor ? "Stopped for battery protection (\(percent)% remaining)." : nil
    }

    /// Safety stops fail closed. Once Hinge's clamshell bit is cleared with the lid closed, XNU re-runs its own
    /// lid-closed sleep decision (IOPMrootDomain::setClamShellSleepDisable → kLocalEvalClamshellCommand).
    /// IOPMSleepSystem is the explicit request; it needs a console login session, so when it is refused the
    /// recorded SPI pulse re-triggers the kernel decision for any user.
    private func finishSafetySleep() -> Bool {
        guard sleepPending else { return true }
        guard IOPM.snapshot().lidClosed == true, !Displays.hasExternal else {
            sleepPending = false
            lastError = nil
            return true
        }
        if !PowerSleep.sleepNow() {
            do {
                try Watchdog.recheckLidSleep()
                fputs("Hinge: explicit sleep was refused (no console session); asked macOS to re-check the closed lid\n", stderr)
            } catch {
                lastError = "Sleep protection was released, but macOS could not be asked to sleep. \(error.localizedDescription)"
                fputs("Hinge: \(lastError ?? "")\n", stderr)
                return false
            }
        }
        sleepPending = false
        lastError = nil
        return true
    }

    var state: SessionState {
        SessionState(armed: armed, paused: paused, armMode: armMode, needsRecovery: needsRecovery, anotherSession: anotherSession,
                     error: lastError ?? recoveryReadError, notice: notice, title: statusTitle, detail: statusLine)
    }
}
