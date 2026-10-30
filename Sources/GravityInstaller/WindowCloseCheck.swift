// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import GravityCore

/// A separate demo process tests the real red-button path. Success requires the
/// process to terminate naturally; no explicit successful exit can mask a leak.
@MainActor enum WindowCloseCheck {
    static func run(model: InstallerModel, report: URL) async throws {
        try await Task.sleep(nanoseconds: 250_000_000)
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.title == "Install Gravity Linux" }) else { throw InstallerError("The installer window is missing") }
        model.busy = true; model.screen = .installing
        main.performClose(nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        guard main.isVisible else { throw InstallerError("The close button hid an active installation") }
        model.busy = false; model.screen = .welcome
        DeveloperOptionsWindow.shared.show(model: model)
        try await Task.sleep(nanoseconds: 150_000_000)
        guard NSApp.windows.contains(where: { $0.isVisible && $0.title == "Developer Options" }) else { throw InstallerError("Developer Options did not open") }
        let data = try JSONSerialization.data(withJSONObject: ["activeInstallCloseBlocked": true, "idleRedCloseRequested": true, "developerOptionsOpen": true], options: [.sortedKeys])
        try data.write(to: report)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            FileHandle.standardError.write(Data("Closing the installer left its process running.\n".utf8))
            exit(1)
        }
        main.performClose(nil)
    }
}
