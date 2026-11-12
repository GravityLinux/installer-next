// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// The current SFR release describes the installed system-wide firmware,
/// independently of the running macOS and the restore selected for the stub.
/// See https://asahilinux.org/docs/platform/stock-partition-layout/
enum SystemFirmware {
    static let versionPath = "/System/Volumes/iSCPreboot/SFR/current/SystemVersion.plist"

    static func components(_ version: String) -> [UInt64]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let numbers = parts.compactMap { UInt64($0) }
        guard numbers.count == parts.count else { return nil }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func validate(minimum: String?, commands: any CommandRunning) throws {
        guard let minimum else { return }
        guard let required = components(minimum) else { throw InstallerError("Invalid system firmware requirement") }
        let version: String
        let installed: [UInt64]
        do {
            // Reading through plutil keeps this preflight unprivileged and
            // uses the same command boundary as other system inspection.
            let data = try commands.run("/usr/bin/plutil", ["-convert", "xml1", "-o", "-", versionPath], input: nil)
            guard let value = try plist(data)["ProductVersion"] as? String,
                  let parsed = components(value) else { throw InstallerError("Missing or invalid system firmware version") }
            version = value; installed = parsed
        } catch {
            throw InstallerError("Couldn’t verify this Mac’s system firmware. Update macOS to \(minimum) or later, restart your Mac, then try again.")
        }
        try require(!installed.lexicographicallyPrecedes(required),
            "This Mac’s system firmware is \(version). Gravity Linux requires \(minimum) or later. Update macOS in System Settings, restart your Mac, then try again.")
    }
}
