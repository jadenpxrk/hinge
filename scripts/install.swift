import Darwin
import Foundation

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: executable, code: Int(process.terminationStatus))
    }
}

func install(from source: URL, to destination: URL) throws {
    let files = FileManager.default
    // Stage beside the destination so the final rename stays on one filesystem.
    let temporary = destination.deletingLastPathComponent()
        .appendingPathComponent(".hinge-install-\(UUID().uuidString)")
    try files.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: temporary) }
    let staged = temporary.appendingPathComponent("Hinge.app")
    try run("/usr/bin/ditto", [source.path, staged.path])
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])

    // Swap whole bundles atomically: the watchdog's executable path never disappears.
    if renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP)) == 0 { return }
    guard errno == ENOENT else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    // First install. Do not overwrite a destination created concurrently.
    guard renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

guard CommandLine.arguments.count == 3 else {
    fputs("usage: install source.app destination.app\n", stderr)
    exit(2)
}
do {
    try install(from: URL(fileURLWithPath: CommandLine.arguments[1]),
                to: URL(fileURLWithPath: CommandLine.arguments[2]))
} catch {
    fputs("Hinge installation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
