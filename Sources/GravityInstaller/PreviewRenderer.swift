// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import AppKit
import GravityCore

@MainActor enum PreviewRenderer {
    static func render(model: InstallerModel, to directory: URL) async throws {
        model.plan = try await model.engine.plan(InstallSelection(targetID: model.targetID, softwareID: model.softwareID, bytes: 120_000_000_000))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, screen) in [("welcome", Screen.welcome), ("storage", .storage), ("software", .software), ("review", .review), ("installing", .installing), ("restart", .restart), ("finalize", .finalize), ("complete", .complete), ("unsupported", .unsupported), ("developer-board", .unsupported)] {
            model.screen = screen
            if screen == .unsupported {
                model.supportIssue = BoardSupportError(reason: name == "developer-board" ? .developerRequired : .unsupported,
                    productNumber: name == "developer-board" ? "j700" : "j999", supportedBoards: ["j773g"])
            }
            if screen == .installing { model.progress = InstallEvent(.systemImage, fraction: 0.64); model.details = ["Resized Macintosh HD", "Created Gravity Linux startup volume", "Collected this Mac’s firmware", "Writing the Linux system image"] }
            if screen == .finalize { model.stage2 = try await model.engine.stage2Status() }
            // Cache an actual hosting view: ImageRenderer omits AppKit-backed
            // scroll views and controls, which would produce an empty main pane.
            let host = NSHostingView(rootView: InstallerView(model: model).frame(width: 880, height: 556).preferredColorScheme(.light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 556), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host; window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            window.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw InstallerError("Could not render the \(name) preview") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw InstallerError("Could not encode the \(name) preview") }
            try data.write(to: directory.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        print("Rendered ten demo screens to \(directory.path)")
    }
}
