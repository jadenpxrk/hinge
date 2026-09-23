import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import os

/// IOPMrootDomain lid-sleep SPI and sensors.
///
/// Lid-close sleep is **not** an idle assertion. XNU decides it in
/// `IOPMrootDomain::shouldSleepOnClamshellClosed()`, gated by
/// `clamshellSleepDisableMask`. The unprivileged user-client method
/// `kPMSetClamshellSleepState` (selector **12**) on `RootDomainUserClient`
/// calls `setClamShellSleepDisable(..., kClamshellSleepDisablePowerd)`.
/// `checkEntitlement` is NULL; the bit is process-independent and dies on reboot.
enum IOPM {
    static let kPMSetClamshellSleepState: UInt32 = 12
    /// `iokit_family_msg(sub_iokit_powermanagement, 0x100)` = 0xE0034100
    static let kIOPMMessageClamshellStateChange: UInt32 = 0xE0034100
    static let clamshellStateKey = "AppleClamshellState"
    static let clamshellCausesSleepKey = "AppleClamshellCausesSleep"
    static let sleepDisabledKey = "SleepDisabled"

    struct Snapshot {
        var lidClosed: Bool?
        var clamshellCausesSleep: Bool?
        var sleepDisabled: Bool?
    }

    static func snapshot() -> Snapshot {
        var s = Snapshot()
        guard let rd = rootDomain() else { return s }
        defer { IOObjectRelease(rd) }
        s.lidClosed = boolProperty(rd, clamshellStateKey)
        s.clamshellCausesSleep = boolProperty(rd, clamshellCausesSleepKey)
        s.sleepDisabled = boolProperty(rd, sleepDisabledKey)
        return s
    }

    static func rootDomain() -> io_service_t? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        return svc == 0 ? nil : svc
    }

    static func boolProperty(_ service: io_service_t, _ key: String) -> Bool? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        let value = raw.takeRetainedValue()
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }
}

/// Holds a `RootDomainUserClient` and toggles `kPMSetClamshellSleepState`.
final class ClamshellSPI {
    private var connection: io_connect_t = 0

    @discardableResult
    func open() -> Bool {
        if connection != 0 { return true }
        guard let rd = IOPM.rootDomain() else { return false }
        defer { IOObjectRelease(rd) }
        let kr = IOServiceOpen(rd, mach_task_self_, 0, &connection)
        return kr == KERN_SUCCESS && connection != 0
    }

    func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    @discardableResult
    func setLidSleepDisabled(_ disable: Bool) -> Bool {
        if !open() { return false }
        var input: UInt64 = disable ? 1 : 0
        var outputCount: UInt32 = 0
        let kr = IOConnectCallScalarMethod(
            connection,
            IOPM.kPMSetClamshellSleepState,
            &input,
            1,
            nil,
            &outputCount
        )
        return kr == KERN_SUCCESS
    }

    deinit { close() }
}

final class LidMonitor {
    var onChange: ((Bool) -> Void)?

    private var notifyPort: IONotificationPortRef?
    private var notification: io_object_t = 0
    private var service: io_service_t = 0

    func start() {
        stop()
        guard let rd = IOPM.rootDomain() else { return }
        service = rd
        let port = IONotificationPortCreate(kIOMainPortDefault)
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let kr = IOServiceAddInterestNotification(
            port,
            rd,
            kIOGeneralInterest,
            { refcon, _, messageType, arg in
                guard let refcon else { return }
                let monitor = Unmanaged<LidMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(messageType: messageType, argument: arg)
            },
            selfPtr,
            &notification
        )
        if kr != KERN_SUCCESS {
            stop()
        }
    }

    func stop() {
        if notification != 0 {
            IOObjectRelease(notification)
            notification = 0
        }
        if service != 0 {
            IOObjectRelease(service)
            service = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    private func handle(messageType: natural_t, argument: UnsafeMutableRawPointer?) {
        guard messageType == IOPM.kIOPMMessageClamshellStateChange else { return }
        let bits = UInt(bitPattern: argument.map { Int(bitPattern: $0) } ?? 0)
        let closed = (bits & 1) != 0 // kClamshellStateBit
        onChange?(closed)
    }

    deinit { stop() }
}

enum Battery {
    static func read() -> BatteryReading {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return BatteryReading(percent: nil, onBattery: nil)
        }
        for source in list {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType as String else { continue }
            let state = info[kIOPSPowerSourceStateKey as String] as? String
            let onBattery: Bool? = state == kIOPSBatteryPowerValue as String ? true :
                (state == kIOPSACPowerValue as String ? false : nil)
            var percent: Int?
            if let current = info[kIOPSCurrentCapacityKey as String] as? Int,
               let maximum = info[kIOPSMaxCapacityKey as String] as? Int,
               maximum > 0, current >= 0, current <= maximum {
                percent = Int((Double(current) / Double(maximum) * 100).rounded())
            }
            return BatteryReading(percent: percent, onBattery: onBattery)
        }
        return BatteryReading(percent: nil, onBattery: nil)
    }
}

enum Thermals {
    static var state: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
}

enum PowerSleep {
    static func sleepNow() -> Bool {
        let connection = IOPMFindPowerManagement(mach_task_self_)
        guard connection != 0 else { return false }
        defer { IOServiceClose(connection) }
        return IOPMSleepSystem(connection) == kIOReturnSuccess
    }
}

final class PowerMonitor {
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?
    func start() {
        stop()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
    }
    deinit { stop() }
}

enum IdleHold {
    private struct State: Sendable {
        var assertionID: IOPMAssertionID = 0
        var held = false
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func take() -> Bool {
        state.withLock { state in
            if state.held { return true }
            var id: IOPMAssertionID = 0
            let kr = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Hinge: keep running while lid sleep is disabled" as CFString,
                &id
            )
            if kr == kIOReturnSuccess {
                state.assertionID = id
                state.held = true
            }
            return state.held
        }
    }

    static func release() {
        state.withLock { state in
            if !state.held { return }
            IOPMAssertionRelease(state.assertionID)
            state.assertionID = 0
            state.held = false
        }
    }
}
