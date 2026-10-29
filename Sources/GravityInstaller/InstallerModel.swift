// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import AppKit
import GravityCore

enum Screen: Int { case checking = -2, authorize = -1, welcome, storage, software, review, installing, restart, finalize, complete, existing, failure, removed, unsupported }
@MainActor final class InstallerModel: ObservableObject {
    @Published var screen: Screen = .checking
    @Published var inspection: Inspection?
    @Published var plan: InstallPlan?
    @Published var maintenance: MaintenancePlan?
    @Published var progress = InstallEvent(.inspecting)
    @Published var details: [String] = []
    @Published var error: String?
    @Published var supportIssue: BoardSupportError?
    @Published var safety = false
    @Published var developerSheet = false
    @Published var credentialsSheet = false
    @Published var busy = false
    @Published var showDetails = false
    @Published var targetID = ""
    @Published var softwareID = ""
    @Published var volumeName = "Gravity Linux"
    @Published var sizeGB: Double = 120
    @Published var username = ""
    @Published var password = ""
    @Published var developer = false
    @Published var customCatalog = ""
    @Published var customRepository = ""
    @Published var stage2: Stage2Status?
    @Published var selectedExisting = ""
    let launch: LaunchOptions
    var engine: InstallerEngine!
    var lastStep: InstallStep?
    var lastOperationTitle: String?
    init() {
        launch = try! LaunchOptions(); developer = launch.configuration.developer
        customCatalog = launch.configuration.catalogURL?.absoluteString ?? ""
        customRepository = launch.configuration.repositoryURL?.absoluteString ?? ""
        createEngine()
    }
    func createEngine() {
        var configuration = launch.configuration; configuration.developer = developer
        if developer {
            configuration.catalogURL = customCatalog.isEmpty ? nil : URL(string: customCatalog)
            configuration.repositoryURL = customRepository.isEmpty ? nil : URL(string: customRepository)
        }
        engine = InstallerEngine(configuration: configuration) { [weak self] event in Task { @MainActor in self?.receive(event) } }
    }
    func applyDeveloperOptions() async {
        for text in [customCatalog, customRepository] where developer && !text.isEmpty {
            guard let url = URL(string: text), url.isFileURL || url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")) else {
                error = "Use an HTTPS URL, a local file URL, or HTTP on localhost for testing."; return
            }
        }
        developerSheet = false; createEngine(); await load()
    }
    func receive(_ event: InstallEvent) {
        progress = event
        if lastStep != event.step || lastOperationTitle != event.title {
            details.append(event.title + (event.detail.map { ": " + $0 } ?? "")); lastStep = event.step; lastOperationTitle = event.title
            if details.count > 300 { details.removeFirst() }
        }
    }
    var target: StorageTarget? { inspection?.targets.first { $0.id == targetID } }
    var software: Software? { inspection?.software.first { $0.id == softwareID } }
    var board: BoardPresentation? { inspection?.board ?? stage2?.board }
    var minimumGB: Double { Double(software?.minimumBytes ?? 30_000_000_000) / 1e9 }
    var maximumGB: Double { Double(target?.maximumBytes ?? 30_000_000_000) / 1e9 }
    var active: Int {
        switch screen {
        case .storage: return 1
        case .software: return 2
        case .review: return 3
        case .installing: return stage2 == nil ? 4 : 6
        case .restart: return 5
        case .finalize, .complete: return 6
        default: return 0
        }
    }
    func load() async {
        guard !busy else { return }
        busy = true; screen = .checking; error = nil; supportIssue = nil; inspection = nil; stage2 = nil; plan = nil; maintenance = nil
        defer { busy = false }
        do {
            _ = try await engine.checkBoardSupport()
            if geteuid() != 0 && !launch.configuration.demo { screen = .authorize; return }
            if launch.configuration.stage2URL != nil {
                let status = try await engine.stage2Status(); stage2 = status; volumeName = status.name
                screen = status.complete ? .complete : .finalize
            } else {
                let info = try await engine.inspect(); inspection = info
                targetID = info.targets.first?.id ?? ""; softwareID = info.software.first?.id ?? ""
                username = info.administrator; selectedExisting = info.existing.first?.id ?? ""
                clampSize(); screen = info.existing.isEmpty ? .welcome : .existing
            }
        } catch let issue as BoardSupportError { supportIssue = issue; screen = .unsupported }
          catch { self.error = error.localizedDescription; screen = .failure }
    }
    func clampSize() { sizeGB = min(max(sizeGB, minimumGB), max(minimumGB, maximumGB)) }
    func review() async {
        busy = true; defer { busy = false }
        do {
            maintenance = nil
            plan = try await engine.plan(InstallSelection(targetID: targetID, softwareID: softwareID, bytes: Int64(sizeGB * 1e9), name: volumeName))
            screen = .review
        } catch { self.error = error.localizedDescription }
    }
    func reviewMaintenance(_ operation: String) async {
        busy = true; defer { busy = false }
        do { maintenance = try await engine.planMaintenance(installationID: selectedExisting, operation: operation); plan = nil; screen = .review }
        catch { self.error = error.localizedDescription }
    }
    func install() async {
        let auth = Credentials(username: username, password: password)
        password = ""; credentialsSheet = false; screen = .installing; busy = true; details = []; lastStep = nil
        defer { busy = false }
        do {
            if stage2 != nil { try await engine.finalize(credentials: auth); screen = .complete }
            else if let maintenance {
                try await engine.maintain(planID: maintenance.id, credentials: auth); screen = maintenance.operation == "uninstall" ? .removed : .restart
            } else if let plan { try await engine.install(planID: plan.id, credentials: auth); screen = .restart }
            else { throw InstallerError("Review an installation plan first") }
        } catch { self.error = error.localizedDescription; screen = .failure }
    }
    func power(restart: Bool) async {
        do { try await engine.powerOff(restart: restart); if launch.configuration.demo { error = "Demo: a real installation would \(restart ? "restart" : "shut down") now." } }
        catch { self.error = error.localizedDescription }
    }
    func authorize() async {
        busy = true; defer { busy = false }
        do {
            func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            var arguments = Array(CommandLine.arguments.dropFirst()).filter { !["--gui", "--developer", "--no-developer"].contains($0) }
            arguments.append(developer ? "--developer" : "--no-developer")
            if developer && !customCatalog.isEmpty { arguments += ["--catalog", customCatalog] }
            if developer && !customRepository.isEmpty { arguments += ["--repository", customRepository] }
            arguments.insert("--gui", at: 0)
            let command = ([CommandLine.arguments[0]] + arguments).map(quote).joined(separator: " ") + " >/dev/null 2>&1 &"
            let script = "do shell script \"" + command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\" with administrator privileges"
            try await Task.detached { _ = try SystemCommands().run("/usr/bin/osascript", ["-e", script], input: nil) }.value
            NSApplication.shared.terminate(nil)
        } catch { self.error = error.localizedDescription }
    }
}
