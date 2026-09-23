import AppKit

struct SessionState: Sendable {
    var armed = false
    var paused = false
    var armMode: ArmMode = .persistent
    var needsRecovery = false
    var anotherSession = false
    var error: String?
    var notice: String?
    var title = "Checking sleep status…"
    var detail = ""
    var canTurnOff: Bool { armed || needsRecovery || anotherSession }
}

enum SessionAction: Equatable, Sendable {
    case arm(ArmMode), turnOff, toggle, refresh, restoreLocal, lidChanged(Bool)
}

enum ArmMode: String, Sendable {
    case nextClose
    case persistent
}

private actor EngineWorker {
    private let engine: StayEngine

    init(engine: StayEngine) { self.engine = engine }

    func perform(_ action: SessionAction) -> (Bool, SessionState) {
        let ok: Bool
        switch action {
        case .arm(let mode): ok = engine.arm(mode: mode)
        case .turnOff: ok = engine.turnOff()
        case .toggle: ok = engine.toggle()
        case .restoreLocal: ok = engine.disarm(reason: "quit")
        case .refresh: engine.tickOnce(); ok = true
        case .lidChanged(let closed):
            engine.updateLid(closed)
            engine.tickOnce()
            ok = true
        }
        if case .arm = action { engine.tickOnce() }
        if action == .toggle { engine.tickOnce() }
        return (ok, engine.state)
    }

    func restoreAtExit() { engine.restoreBestEffort() }
}

/// Main-actor UI state; an actor owns all sleep-control operations.
@MainActor
final class SessionController {
    /// Owns the production engine; exit paths reach it without touching the main actor.
    private nonisolated static let sharedWorker = EngineWorker(engine: StayEngine())
    static let shared = SessionController(worker: sharedWorker)
    typealias Action = SessionAction
    private nonisolated let worker: EngineWorker
    private let lid = LidMonitor()
    private let gesture = CloseGesture()
    private let power = PowerMonitor()
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var inFlight = false
    private var refreshPending = false
    private var pending: [(Action, ((Bool) -> Void)?)] = []
    private(set) var state = SessionState()
    private(set) var busy: String?
    var onChange: (() -> Void)?
    init(engine: sending StayEngine = StayEngine()) { worker = EngineWorker(engine: engine) }
    private init(worker: EngineWorker) { self.worker = worker }

    func startMonitoring() {
        guard timer == nil else { return }
        lid.onChange = { [weak self] closed in self?.perform(.lidChanged(closed)) }
        lid.start()
        gesture.onArm = { [weak self] in
            guard let self, !self.state.canTurnOff, self.busy == nil else { return }
            self.perform(.arm(.nextClose))
        }
        gesture.start()
        power.onChange = { [weak self] in self?.perform(.refresh) }
        power.start()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.gesture.stop() }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in
            self?.gesture.start()
            self?.perform(.refresh)
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.screensDidSleepNotification] {
            observe(workspace, name) { [weak self] in self?.perform(.refresh) }
        }
        _ = ProcessInfo.processInfo.thermalState
        observe(.default, ProcessInfo.thermalStateDidChangeNotification) { [weak self] in self?.perform(.refresh) }
        let tick = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.perform(.refresh) }
        }
        timer = tick
        RunLoop.main.add(tick, forMode: .common)
        perform(.refresh)
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        gesture.stop()
        lid.stop()
        power.stop()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @MainActor @Sendable @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in action() }
        }
        observers.append((center, token))
    }

    func perform(_ action: Action, completion: ((Bool) -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        if inFlight {
            if action == .refresh && completion == nil { refreshPending = true }
            else { pending.append((action, completion)) }
            return
        }
        inFlight = true
        switch action {
        case .arm: busy = "Starting awake session…"
        case .turnOff, .restoreLocal: busy = "Restoring sleep…"
        case .toggle: busy = state.canTurnOff ? "Restoring sleep…" : "Starting awake session…"
        case .refresh, .lidChanged: break
        }
        onChange?()
        Task { [weak self] in
            guard let self else { return }
            let (ok, snapshot) = await worker.perform(action)
            state = snapshot
            busy = nil
            inFlight = false
            onChange?()
            let armedAction = if case .arm = action { true } else { false }
            completion?(ok && !snapshot.needsRecovery && (!armedAction || snapshot.armed))
            if !pending.isEmpty {
                let (next, done) = pending.removeFirst()
                perform(next, completion: done)
            } else if refreshPending {
                refreshPending = false
                perform(.refresh)
            }
        }
    }

    func result(for action: Action) async -> String {
        await withCheckedContinuation { continuation in
            if action != .refresh { startMonitoring() }
            perform(action) { _ in
                continuation.resume(returning: self.state.error ?? (action == .refresh ? self.state.detail : self.state.title))
            }
        }
    }

    /// atexit fallback for exits that skipped `.restoreLocal`. Waits only on the engine actor, which never
    /// hops to the main actor, so blocking the exiting thread cannot deadlock.
    nonisolated static func restoreAtExit() {
        guard StateFile.ownsLock else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached { await sharedWorker.restoreAtExit(); done.signal() }
        done.wait()
    }
}
