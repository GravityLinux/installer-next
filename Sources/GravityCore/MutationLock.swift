// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Serialize mutations across separate GUI, TUI, and API processes as well as
/// within one engine actor. The descriptor closes automatically after a crash.
final class MutationLock {
    private let descriptor: Int32
    init(path: String = "/var/run/gravity-installer.lock") throws {
        descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        try require(descriptor >= 0, "Could not open the installer operation lock")
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            throw InstallerError("Another Gravity Linux installer is changing this Mac. Wait for it to finish.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
