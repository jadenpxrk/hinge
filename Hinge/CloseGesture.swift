import AppKit

struct ClosingMotion {
    private var optionSince: TimeInterval?
    private var origin: Double?
    private var previous: Double?
    private var lastSample: TimeInterval?
    private var closingSamples = 0
    private var fired = false

    mutating func reset() { self = ClosingMotion() }

    mutating func sample(option: Bool, angle: Double?, now: TimeInterval) -> Bool {
        guard option else { reset(); return false }
        if optionSince == nil { optionSince = now }
        guard !fired else { return false }
        guard let angle, angle.isFinite, (0...200).contains(angle) else {
            origin = nil; previous = nil; closingSamples = 0; lastSample = nil
            return false
        }
        defer { previous = angle; lastSample = now }
        if let lastSample, now - lastSample > 0.2 { origin = nil; previous = nil; closingSamples = 0 }
        guard let previous, let origin else { self.origin = angle; return false }
        let delta = previous - angle
        if abs(delta) > 30 || delta < -2 {
            self.origin = angle
            closingSamples = 0
            return false
        }
        if delta > 0.25 { closingSamples += 1 }
        guard now - (optionSince ?? now) >= 0.15, origin - angle >= 6, closingSamples >= 2 else { return false }
        fired = true
        return true
    }
}

@MainActor
final class CloseGesture {
    var onArm: (() -> Void)?
    private let sensor = LidAngle()
    private var timer: Timer?
    private var motion = ClosingMotion()
    private var fast = false
    private var nextReconnect: TimeInterval = 0
    private let isOptionHeld: () -> Bool

    init(isOptionHeld: @escaping () -> Bool = { NSEvent.modifierFlags.contains(.option) }) {
        self.isOptionHeld = isOptionHeld
    }

    func start() {
        stop()
        schedule(fast: false)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sensor.stop()
        motion.reset()
        fast = false
        nextReconnect = 0
    }

    private func schedule(fast: Bool) {
        timer?.invalidate()
        self.fast = fast
        let timer = Timer(timeInterval: fast ? 0.025 : 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = fast ? 0.005 : 0.03
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        let option = isOptionHeld()
        let now = ProcessInfo.processInfo.systemUptime
        guard option else {
            motion.reset()
            if fast { sensor.stop(); schedule(fast: false) }
            return
        }
        if !fast { schedule(fast: true); nextReconnect = 0 }
        if !sensor.available, now >= nextReconnect {
            sensor.start()
            nextReconnect = now + 1
        }
        if motion.sample(option: true, angle: sensor.read(), now: now) { onArm?() }
    }
}
