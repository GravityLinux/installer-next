// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import AppKit
import GravityCore

@MainActor enum PreviewRenderer {
    static func render(model: InstallerModel, to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await checkDeveloperWindow(model: model, directory: directory)
        model.renderingPreview = true
        var inspection = try await model.engine.inspect(); inspection.software = try await model.engine.availableSoftware()
        model.inspection = inspection; model.softwareID = inspection.software.first?.id ?? ""
        guard model.allocationBytes == 0 && abs(model.macOSGB-model.partitionTotalGB) < 0.001 else { throw InstallerError("An unpartitioned install did not start with Linux at zero") }
        model.setMacOSGB(model.partitionTotalGB - 120)
        guard abs(Double(model.allocationBytes)/1e9 - 120) < 0.002 else { throw InstallerError("Moving the boundary left did not allocate space to Linux") }
        model.plan = try await model.engine.plan(InstallSelection(targetID: model.targetID, softwareID: model.softwareID, bytes: 120_000_000_000))
        let status = try await model.engine.stage2Status()
        let screens: [(String, Screen)] = [("checking", .checking), ("existing", .existing), ("welcome", .welcome), ("safety", .welcome),
            ("storage", .storage), ("software", .software), ("review", .review), ("installing", .installing), ("restart", .restart),
            ("macos-instead", .finalize), ("finalize", .finalize), ("administrator", .finalize), ("complete", .complete),
            ("software-developer", .software), ("unsupported", .unsupported), ("developer-board", .unsupported)]
        for (name, screen) in screens {
            model.screen = screen; model.safety = name == "safety"; model.credentialsSheet = name == "administrator"
            model.stage2 = nil; model.inspection = inspection; model.developer = name == "software-developer"
            model.sizeGB = name == "storage" ? 0 : 120
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
        model.screen = .storage; model.inspection = inspection; model.targetID = inspection.targets[0].id; model.sizeGB = 120
        try await snapshot(InstallerView(model: model), size: NSSize(width: 880, height: 600), to: directory.appendingPathComponent("storage-selected.png"))
        model.safety = false; model.credentialsSheet = false; model.developer = false
        try await fittingSnapshot(DeveloperOptionsView(model: model, previewEnabled: false), to: directory.appendingPathComponent("developer-options-off.png"))
        try await fittingSnapshot(DeveloperOptionsView(model: model, previewEnabled: true), to: directory.appendingPathComponent("developer-options-on.png"))
        model.screen = .storage; model.inspection = try changing(inspection, ["targets": [
            ["id": "demo-no-shrink", "name": "Macintosh HD", "kind": "resize", "totalBytes": 80_000_000_000, "freeBytes": 5_000_000_000, "maximumBytes": 79_999_008_768,
             "existingFreeBytes": 79_999_008_768]]])
        model.targetID = "demo-no-shrink"; model.sizeGB = Double(model.target!.unallocatedBytes) / 1e9
        guard abs(model.macOSGB/model.partitionTotalGB - 0.5) < 0.001 else { throw InstallerError("Existing space did not give a proportional starting boundary") }
        try await snapshot(InstallerView(model: model), size: NSSize(width: 880, height: 600), to: directory.appendingPathComponent("storage-no-shrink.png"))
        model.inspection = try changing(model.inspection!, ["targets": [["id": "demo-no-shrink", "name": "Macintosh HD", "kind": "resize", "totalBytes": 80_000_000_000, "freeBytes": 20_000_000_000,
            "maximumBytes": 97_998_307_328, "existingFreeBytes": 79_999_008_768]]])
        try await snapshot(InstallerView(model: model), size: NSSize(width: 880, height: 600), to: directory.appendingPathComponent("storage-existing-space.png"))
        model.setMacOSGB(70)
        guard model.allocationBytes > model.target!.unallocatedBytes else { throw InstallerError("Moving left did not reclaim more macOS space") }
        try await snapshot(InstallerView(model: model), size: NSSize(width: 880, height: 600), to: directory.appendingPathComponent("storage-extra-shrink.png"))
        model.setMacOSGB(100)
        guard model.allocationBytes < model.target!.unallocatedBytes && abs(model.macOSGB - 100) < 0.002 else { throw InstallerError("Moving right did not give more space to macOS") }
        try await snapshot(InstallerView(model: model), size: NSSize(width: 880, height: 600), to: directory.appendingPathComponent("storage-more-macos.png"))
        model.inspection = try changing(inspection, ["targets": [["id": "demo-insufficient", "name": "Macintosh HD", "kind": "resize", "totalBytes": 80_000_000_000, "freeBytes": 3_000_000_000,
            "maximumBytes": 999_292_928, "existingFreeBytes": 0]]])
        model.targetID = "demo-insufficient"; model.sizeGB = 0
        guard model.insufficientCapacity && !model.validAllocation else { throw InstallerError("Insufficient capacity was not blocked") }
        try await snapshot(InstallerView(model: model), size: NSSize(width: 880, height: 600), to: directory.appendingPathComponent("storage-insufficient.png"))
        try JSONSerialization.data(withJSONObject: ["noFreeStartsLinuxAtZero": true, "freeSpaceSetsProportionalStart": true, "leftGivesLinuxMore": true, "rightGivesMacOSMore": true, "insufficientCapacityBlocked": true], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("allocation-check.json"))
        print("Rendered twenty-four demo views to \(directory.path)")
    }
    private static func checkDeveloperWindow(model: InstallerModel, directory: URL) async throws {
        guard let installer = NSApp.windows.first(where: { $0.isVisible && $0.title == "Install Gravity Linux" }) else { throw InstallerError("The installer window is missing") }
        model.developer = true
        DeveloperOptionsWindow.shared.show(model: model)
        try await Task.sleep(nanoseconds: 300_000_000)
        guard let options = NSApp.windows.first(where: { $0.isVisible && $0.title == "Developer Options" }), let content = options.contentView else { throw InstallerError("Developer Options did not open") }
        let height = options.frame.height, fitting = content.fittingSize.height
        let expected = NSHostingView(rootView: DeveloperOptionsView(model: model, previewEnabled: true)).fittingSize.height
        guard abs(height-fitting) <= 1 && abs(height-expected) <= 1 else { throw InstallerError("Developer Options has excess window chrome space") }
        // Deliberately focus the installer before running the exact operation
        // behind Done: selecting NSApp.keyWindow here would close the wrong UI.
        installer.makeKeyAndOrderFront(nil)
        await DeveloperOptionsWindow.finish(model: model, enabled: true, options: model.developerOptions, window: options)
        guard installer.isVisible && !options.isVisible else { throw InstallerError("Done did not close only Developer Options") }
        let result: [String: Any] = ["doneKeepsInstallerOpen": true, "developerWindowHeight": height, "contentHeight": fitting, "naturalContentHeight": expected]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("window-check.json"))
        model.developer = false; model.createEngine(); await model.load()
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
    private static func fittingSnapshot<V: View>(_ view: V, to url: URL) async throws {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        try await snapshot(view, size: NSSize(width: 520, height: ceil(size.height)), to: url)
    }
}
