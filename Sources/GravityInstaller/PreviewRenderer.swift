// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import AppKit
import GravityCore

@MainActor enum PreviewRenderer {
    static func render(model: InstallerModel, to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.renderingPreview = true
        var inspection = try await model.engine.inspect(); inspection.software = try await model.engine.availableSoftware()
        model.inspection = inspection; model.softwareID = inspection.software.first?.id ?? ""
        model.plan = try await model.engine.plan(InstallSelection(targetID: model.targetID, softwareID: model.softwareID, bytes: 120_000_000_000))
        let status = try await model.engine.stage2Status()
        let screens: [(String, Screen)] = [("checking", .checking), ("existing", .existing), ("welcome", .welcome), ("safety", .welcome),
            ("storage", .storage), ("software", .software), ("review", .review), ("installing", .installing), ("restart", .restart),
            ("macos-instead", .finalize), ("finalize", .finalize), ("administrator", .finalize), ("complete", .complete),
            ("software-developer", .software), ("unsupported", .unsupported), ("developer-board", .unsupported)]
        for (name, screen) in screens {
            model.screen = screen; model.safety = name == "safety"; model.credentialsSheet = name == "administrator"
            model.stage2 = nil; model.inspection = inspection; model.developer = name == "software-developer"
            if name == "existing" {
                model.inspection = try changing(inspection, ["existing": [["id": "demo-existing", "name": "Gravity Linux", "needsFinalization": false, "canUninstall": true]]])
                model.selectedExisting = "demo-existing"
            }
            if screen == .installing { model.progress = InstallEvent(.systemFiles, fraction: 0.64); model.details = ["Resized Macintosh HD to 374 GB", "Created Gravity Linux partition (120 GB)", "Downloaded the selected Linux image", "Copying system files"] }
            if screen == .finalize { model.stage2 = name == "macos-instead" ? try changing(status, ["in1TR": false, "paired": false]) : status }
            if screen == .unsupported {
                model.supportIssue = BoardSupportError(reason: name == "developer-board" ? .developerRequired : .unsupported,
                    productNumber: name == "developer-board" ? "j700" : "j999", supportedBoards: ["j773g"])
            }
            if name == "software-developer" { model.createEngine(); model.inspection = try await model.engine.inspect(); model.inspection?.software = try await model.engine.availableSoftware() }
            try await snapshot(InstallerView(model: model), size: NSSize(width: 880, height: 600), to: directory.appendingPathComponent(name + ".png"))
        }
        model.safety = false; model.credentialsSheet = false; model.developer = false
        try await snapshot(DeveloperOptionsView(model: model, previewEnabled: false), size: NSSize(width: 520, height: 220), to: directory.appendingPathComponent("developer-options-off.png"))
        try await snapshot(DeveloperOptionsView(model: model, previewEnabled: true), size: NSSize(width: 520, height: 640), to: directory.appendingPathComponent("developer-options-on.png"))
        model.screen = .storage; model.inspection = try changing(inspection, ["targets": [
            ["id": "demo-no-shrink", "name": "Macintosh HD", "kind": "resize", "totalBytes": 80_000_000_000, "freeBytes": 5_000_000_000, "maximumBytes": 0,
             "unavailableReason": "macOS has 5 GB free. At least 40 GB must remain free after shrinking. Free space in macOS to enable this option."],
            ["id": "demo-free", "name": "Available space after disk0s2", "kind": "free", "totalBytes": 80_000_000_000, "freeBytes": 80_000_000_000, "maximumBytes": 79_999_000_000]]])
        model.targetID = "demo-free"; model.sizeGB = 60
        try await snapshot(InstallerView(model: model), size: NSSize(width: 880, height: 600), to: directory.appendingPathComponent("storage-no-shrink.png"))
        print("Rendered nineteen demo views to \(directory.path)")
    }
    private static func changing<T: Codable>(_ value: T, _ fields: [String: Any]) throws -> T {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        for (key, field) in fields { object[key] = field }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private static func snapshot<V: View>(_ view: V, size: NSSize, to url: URL) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(.light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil); host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        window.makeFirstResponder(nil); window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw InstallerError("Could not render the preview") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw InstallerError("Could not encode the preview") }
        try data.write(to: url); window.orderOut(nil)
    }
}
