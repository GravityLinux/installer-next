// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import AppKit
import GravityCore

enum Screen: Int { case checking = -1, welcome, storage, software, review, installing, restart, finalize, complete, existing, failure, removed, unsupported }
@MainActor final class InstallerModel: ObservableObject {
    @Published var screen: Screen = .checking
    @Published var inspection: Inspection?
    @Published var plan: InstallPlan?
    @Published var maintenance: MaintenancePlan?
    @Published var progress = InstallEvent(.inspecting)
    @Published var details: [String] = []
    @Published var error: String?
    @Published var supportIssue: BoardSupportError?
    @Published var failureTitle = "Couldn’t check this Mac"
    @Published var changesMayHaveStarted = false
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
    @Published var developerOptions = DeveloperOptions()
    var renderingPreview = false
    @Published var stage2: Stage2Status?
    @Published var selectedExisting = ""
    let launch: LaunchOptions
    var engine: InstallerSession!
    var lastStep: InstallStep?
    var lastOperationTitle: String?
    init() {
        launch = try! LaunchOptions(); developer = launch.configuration.developer; developerOptions = launch.configuration.developerOptions
        createEngine()
    }
    func createEngine() {
        var configuration = launch.configuration; configuration.developer = developer
        configuration.developerOptions = developerOptions
        if developer, let sources = try? developerOptions.sources(defaultCatalog: configuration.catalogURL, defaultRepository: configuration.repositoryURL) {
            configuration.catalogURL = sources.catalog; configuration.repositoryURL = sources.repository
        }
        engine = InstallerSession(configuration: configuration) { [weak self] event in Task { @MainActor in self?.receive(event) } }
    }
    func applyDeveloperOptions(enabled: Bool, options: DeveloperOptions) async {
        let previous = screen, oldTarget = targetID, oldSoftware = softwareID, oldSize = sizeGB
        developer = enabled; developerOptions = options; developerSheet = false; createEngine(); await load()
        if inspection != nil && [.welcome, .storage, .software].contains(previous) {
            if inspection?.targets.contains(where: { $0.id == oldTarget && $0.unavailableReason == nil }) == true { targetID = oldTarget; sizeGB = oldSize }
            if inspection?.software.contains(where: { $0.id == oldSoftware }) == true { softwareID = oldSoftware }
            clampSize(); screen = previous
            if previous == .software { await chooseSoftware() }
        }
    }
    func receive(_ event: InstallEvent) {
        if [InstallStep.resize, .createStub, .volumes, .partition, .securityPolicy, .reducedSecurity, .uninstall, .repair].contains(event.step) { changesMayHaveStarted = true }
        progress = event
        if lastStep != event.step || lastOperationTitle != event.title {
            details.append(event.title + (event.detail.map { ": " + $0 } ?? "")); lastStep = event.step; lastOperationTitle = event.title
            if details.count > 300 { details.removeFirst() }
        }
    }
    var target: StorageTarget? { inspection?.targets.first { $0.id == targetID } }
    var software: Software? { inspection?.software.first { $0.id == softwareID } }
    var board: BoardPresentation? { inspection?.board ?? stage2?.board }
    var requiredInstallBytes: Int64 { software?.minimumBytes ?? inspection?.minimumInstallBytes ?? 30_000_000_000 }
    var maximumGB: Double { Double(target?.maximumBytes ?? 0) / 1e9 }
    var allocationBytes: Int64 { target?.boundedAllocation(Int64((sizeGB * 1e9).rounded())) ?? Int64((sizeGB * 1e9).rounded()) }
    var partitionTotalGB: Double { Double(target?.diagramTotalBytes ?? 0) / 1e9 }
    var macOSGB: Double { partitionTotalGB - Double(allocationBytes) / 1e9 }
    var insufficientCapacity: Bool { target.map { !$0.canAllocate($0.maximumBytes, minimumBytes: requiredInstallBytes) } ?? true }
    var validAllocation: Bool { target?.canAllocate(allocationBytes, minimumBytes: requiredInstallBytes) == true }
    func setMacOSGB(_ value: Double) { sizeGB = max(0, min(maximumGB, partitionTotalGB - value)) }
    var active: Int {
        switch screen {
        case .storage: return 1
        case .software: return 2
        case .review: return 3
        case .installing: return stage2 == nil ? 4 : 6
        case .restart: return 5
        case .finalize: return stage2?.in1TR == true && stage2?.paired == true ? 6 : 5
        case .complete: return -1
        default: return 0
        }
    }
    func load() async {
        guard !busy else { return }
        busy = true; screen = .checking; error = nil; supportIssue = nil; inspection = nil; stage2 = nil; plan = nil; maintenance = nil
        failureTitle = "Couldn’t check this Mac"; changesMayHaveStarted = false
        defer { busy = false }
        do {
            _ = try await engine.checkBoardSupport()
            if launch.configuration.stage2URL != nil {
                let status = try await engine.stage2Status(); stage2 = status; volumeName = status.name
                if status.developerMode { developer = true; developerOptions.allowUnsupportedMacs = true }
                screen = status.complete ? .complete : .finalize
            } else {
                let info = try await engine.inspect(); inspection = info
                softwareID = info.software.first?.id ?? ""
                targetID = info.targets.first(where: { $0.unavailableReason == nil && $0.maximumBytes >= requiredInstallBytes })?.id ?? info.targets.first?.id ?? ""
                sizeGB = Double(target?.unallocatedBytes ?? 0) / 1e9
                username = info.administrator; selectedExisting = info.existing.first?.id ?? ""
                clampSize(); screen = info.existing.isEmpty ? .welcome : .existing
            }
        } catch let issue as BoardSupportError { supportIssue = issue; screen = .unsupported }
          catch { self.error = error.localizedDescription; screen = .failure }
    }
    func clampSize() { sizeGB = min(max(sizeGB, 0), max(0, maximumGB)) }
    func chooseSoftware() async {
        guard !busy else { return }
        screen = .software; busy = true; error = nil
        defer { busy = false }
        do {
            let choices = try await engine.availableSoftware()
            inspection?.software = choices
            if !choices.contains(where: { $0.id == softwareID }) { softwareID = choices.first?.id ?? "" }
            clampSize()
        } catch { self.error = error.localizedDescription }
    }
    func review() async {
        busy = true; defer { busy = false }
        do {
            maintenance = nil
            plan = try await engine.plan(InstallSelection(targetID: targetID, softwareID: softwareID, bytes: allocationBytes, name: volumeName))
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
        changesMayHaveStarted = false
        failureTitle = stage2 != nil ? "Couldn’t finish installation" : maintenance != nil ? "Maintenance stopped" : "Installation stopped"
        progress = InstallEvent(.inspecting, help: "Authorizing this operation with the administrator login you provided.", title: "Authorizing installation")
        defer { busy = false }
        do {
            if stage2 != nil { try await engine.finalize(credentials: auth); screen = .complete }
            else if let maintenance {
                try await engine.maintain(planID: maintenance.id, credentials: auth); screen = maintenance.operation == "uninstall" ? .removed : .restart
            } else if let plan { try await engine.install(planID: plan.id, credentials: auth); screen = .restart }
            else { throw InstallerError("Review an installation plan first") }
        } catch {
            self.error = error.localizedDescription
            if changesMayHaveStarted { screen = .failure }
            else { screen = stage2 != nil ? .finalize : .review }
        }
    }
    func power(restart: Bool) async {
        do { try await engine.powerOff(restart: restart); if launch.configuration.demo { error = "Demo: a real installation would \(restart ? "restart" : "shut down") now." } }
        catch { self.error = error.localizedDescription }
    }
}
