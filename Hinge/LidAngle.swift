import AppKit
import CoreFoundation
import IOKit.hid

/// MacBook hinge angle via HID feature report 1 (Apple VID, Sensor/Orientation).
/// Used to arm lid-sleep disable *before* AppleClamshellState fires.
final class LidAngle {
    static let appleVID = 0x05AC
    static let sensorHubPID = 0x8104
    static let sensorPage = 0x0020
    static let orientationUsage = 0x008A

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private(set) var available = false

    func start() {
        stop()
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        let matches: [[String: Any]] = [
            [
                kIOHIDVendorIDKey as String: Self.appleVID,
                kIOHIDProductIDKey as String: Self.sensorHubPID,
                kIOHIDPrimaryUsagePageKey as String: Self.sensorPage,
                kIOHIDPrimaryUsageKey as String: Self.orientationUsage
            ],
            [
                kIOHIDVendorIDKey as String: Self.appleVID,
                kIOHIDPrimaryUsagePageKey as String: Self.sensorPage,
                kIOHIDPrimaryUsageKey as String: Self.orientationUsage
            ]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        guard let set = IOHIDManagerCopyDevices(mgr) as CFSet? else { return }
        let n = CFSetGetCount(set)
        guard n > 0 else { return }
        let raw = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: n)
        defer { raw.deallocate() }
        CFSetGetValues(set, raw)
        for i in 0..<n {
            let ptr = raw[i]
            guard let ptr else { continue }
            let dev = Unmanaged<IOHIDDevice>.fromOpaque(ptr).takeUnretainedValue()
            if IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
                device = dev
                available = read() != nil
                if available { return }
                IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
                device = nil
            }
        }
    }

    func stop() {
        if let device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        available = false
    }

    @discardableResult
    func read() -> Double? {
        guard let device else { available = false; return nil }
        var report = [UInt8](repeating: 0, count: 8)
        var length: CFIndex = CFIndex(report.count)
        let kr = report.withUnsafeMutableBufferPointer { buf -> IOReturn in
            var len = length
            let r = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, buf.baseAddress!, &len)
            length = len
            return r
        }
        guard kr == kIOReturnSuccess, length >= 3 else { available = false; return nil }
        let raw = UInt16(report[1]) | (UInt16(report[2]) << 8)
        let deg = Double(raw)
        // Sanity: hinge is roughly 0...180. Reject garbage.
        guard deg <= 200 else { available = false; return nil }
        available = true
        return deg
    }

    deinit { stop() }
}
