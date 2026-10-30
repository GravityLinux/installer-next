// SPDX-License-Identifier: GPL-2.0-only
import Foundation

final class InstallationLog: @unchecked Sendable {
    let url: URL?
    private let handle: FileHandle?
    private let lock = NSLock()
    private var previousStep: InstallStep?
    private var previousTitle: String?
    private let verbose: Bool
    init(enabled: Bool, verbose: Bool = true) {
        self.verbose = verbose
        let path = URL(fileURLWithPath: "/var/log/gravity-installer.log")
        if enabled {
            if !fm.fileExists(atPath: path.path) { fm.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            handle = try? FileHandle(forWritingTo: path); _ = try? handle?.seekToEnd(); url = handle == nil ? nil : path
        } else { handle = nil; url = nil }
    }
    func append(_ event: InstallEvent) {
        lock.lock(); defer { lock.unlock() }
        // Log operation boundaries, never user credentials or PTY transcripts.
        if event.step == previousStep && event.title == previousTitle && event.fraction != 1 { return }
        previousStep = event.step; previousTitle = event.title
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(event.step.rawValue) \(event.title)\(verbose ? event.detail.map { " " + $0 } ?? "" : "")\n"
        try? handle?.write(contentsOf: Data(line.utf8))
    }
    deinit { try? handle?.close() }
}
