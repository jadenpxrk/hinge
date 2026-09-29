import Darwin
import Foundation
import os

struct BatteryReading {
    var percent: Int?
    var onBattery: Bool?
}

struct HingeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct DirtyState: Codable {
    var armedAt: Date
    var session: UUID
}

enum StateFile {
    private static let lock = OSAllocatedUnfairLock(initialState: Int32(-1))
    static var ownsLock: Bool { lock.withLock { $0 >= 0 } }

    static func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: Paths.supportDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(Paths.supportDir.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw HingeError(message: "Hinge's recovery folder must be a directory owned by your account.")
        }
        guard chmod(Paths.supportDir.path, 0o700) == 0 else {
            throw HingeError(message: "Could not protect Hinge's recovery folder.")
        }
    }

    /// Held for the whole session. The kernel releases it on exit, including crashes.
    static func acquireLock() throws -> Bool {
        try lock.withLock { lockFD in
            if lockFD >= 0 { return true }
            try prepareDirectory()
            let fd = open(Paths.supportDir.appendingPathComponent("owner.lock").path,
                          O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw HingeError(message: "Could not open the session lock.") }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_nlink == 1 else {
                close(fd)
                throw HingeError(message: "The session lock is not a private regular file.")
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                close(fd)
                if code == EWOULDBLOCK { return false }
                throw HingeError(message: "Could not lock the awake session.")
            }
            lockFD = fd
            return true
        }
    }

    static func releaseLock() {
        lock.withLock { lockFD in
            if lockFD >= 0 { close(lockFD); lockFD = -1 }
        }
    }

    static func markDirty(session: UUID) throws {
        guard ownsLock else { throw HingeError(message: "No ownership of the awake session.") }
        let state = DirtyState(armedAt: Date(), session: session)
        try writeAtomically(JSONEncoder().encode(state), to: Paths.dirtyURL)
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        var template = Array(Paths.supportDir.appendingPathComponent(".state.XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw HingeError(message: "Could not create a private recovery file.") }
        let path = String(cString: template)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { unlink(path) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(path, url.path) == 0 else {
            throw HingeError(message: "Could not save the sleep recovery record.")
        }
    }

    static func readDirty() throws -> DirtyState? {
        // Read one opened inode, even if the owner replaces or removes its path.
        let fd = open(Paths.dirtyURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw HingeError(message: "Could not safely open the sleep recovery record.")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink <= 1, info.st_size <= 8192 else {
            throw HingeError(message: "The recovery record is not a valid user-owned file.")
        }
        let data = try handle.readToEnd() ?? Data()
        return try JSONDecoder().decode(DirtyState.self, from: data)
    }

    static func clearDirty() throws {
        guard ownsLock else { throw HingeError(message: "No ownership of the awake session.") }
        if unlink(Paths.dirtyURL.path) != 0, errno != ENOENT {
            throw HingeError(message: "Sleep was restored, but its recovery record could not be removed.")
        }
        unlink(Paths.stopURL.path)
    }

    static func requestStop(session: UUID) throws {
        try writeAtomically(Data(session.uuidString.utf8), to: Paths.stopURL)
    }

    static func stopRequested(session: UUID) -> Bool {
        (try? String(contentsOf: Paths.stopURL, encoding: .utf8)) == session.uuidString
    }
}

enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() }
        catch { return (-1, error.localizedDescription) }
        // Drain before waiting: a child can fill the pipe and block before it exits.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

enum Watchdog {
    static func installLaunchAgent() throws {
        let plist: [String: Any] = [
            "Label": Paths.launchAgentLabel,
            "ProgramArguments": [Paths.executablePath, "--watchdog"],
            "RunAtLoad": true, "StartInterval": 20, "Nice": 15, "ProcessType": "Background"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let url = Paths.launchAgentURL
        let service = "gui/\(getuid())/\(Paths.launchAgentLabel)"
        if (try? Data(contentsOf: url)) == data, SystemCommands.run("/bin/launchctl", ["print", service]).0 == 0 { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        _ = SystemCommands.run("/bin/launchctl", ["bootout", service])
        let (status, output) = SystemCommands.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", url.path])
        guard status == 0 else {
            throw HingeError(message: "Could not enable crash recovery. \(output)")
        }
    }

    /// Caller must hold the session lock. Unrecorded system settings are never reset.
    static func restoreOwned() throws {
        guard StateFile.ownsLock else { throw HingeError(message: "Another Hinge session is active.") }
        guard try StateFile.readDirty() != nil else { return }
        let spi = ClamshellSPI()
        guard spi.setLidSleepDisabled(false) else {
            throw HingeError(message: "Lid sleep could not be restored. Recovery will retry; keep the Mac ventilated.")
        }
        try StateFile.clearDirty()
    }

    /// Re-runs XNU's lid-closed sleep decision without privileges: the clamshell bit going 1→0 with the lid
    /// closed makes IOPMrootDomain evaluate shouldSleepOnClamshellClosed(). The pulse is recorded so a crash
    /// between the two calls is recovered. A crashed owner's record is restored first so marking the pulse cannot
    /// overwrite it. Returns without pulsing when another Hinge owns the session.
    static func recheckLidSleep() throws {
        guard try StateFile.acquireLock() else { return }
        try restoreOwned()
        try StateFile.markDirty(session: UUID())
        guard ClamshellSPI().setLidSleepDisabled(true) else {
            try StateFile.clearDirty()
            StateFile.releaseLock()
            throw HingeError(message: "The lid-sleep check could not be re-run. Open the lid to wake normally.")
        }
        try restoreOwned()
        StateFile.releaseLock()
    }

    static func runOnce() throws -> String {
        guard try StateFile.acquireLock() else { return "active session; no changes" }
        defer { StateFile.releaseLock() }
        try restoreOwned()
        return "recovery complete; no owned changes remain"
    }

    /// CLI stop waits for the owner instead of racing its reassertion timer.
    static func requestStop(timeout: TimeInterval = 12) throws {
        guard !StateFile.ownsLock else { throw HingeError(message: "Stop the local engine directly.") }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try StateFile.acquireLock() {
                defer { StateFile.releaseLock() }
                try restoreOwned()
                return
            }
            if let dirty = try StateFile.readDirty() {
                try StateFile.requestStop(session: dirty.session)
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw HingeError(message: "Hinge has not confirmed sleep restoration. Open its menu and retry; the recovery record was kept.")
    }
}
