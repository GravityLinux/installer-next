// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import GravityCore

final class TerminalOutput: @unchecked Sendable {
    let lock = NSLock()
    let api: Bool
    init(api: Bool) { self.api = api }
    func printJSON(_ object: Any) {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) { try? FileHandle.standardOutput.write(contentsOf: data + Data([10])) }
    }
    func value<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    func event(_ event: InstallEvent) {
        if api {
            var result: [String: Any] = ["type": "event", "version": 1, "step": event.step.rawValue, "title": event.title, "help": event.help]
            if let fraction = event.fraction { result["fraction"] = fraction }; if let detail = event.detail { result["detail"] = detail }; printJSON(result)
        } else {
            lock.lock(); defer { lock.unlock() }
            if event.fraction == nil || event.fraction == 1 {
                print("\n\(event.fraction == 1 ? "✓" : "→") \(event.title)\(event.detail.map { ": " + $0 } ?? "")\n  \(event.help)")
            } else if isatty(STDOUT_FILENO) != 0 {
                print(String(format: "\r  %3.0f%%", event.fraction! * 100), terminator: ""); fflush(stdout)
            }
        }
    }
}
struct APIRequest: Decodable {
    let id: String, method: String
    let selection: InstallSelection?
    let reviewedPlan: InstallPlan?
    let reviewedMaintenance: MaintenancePlan?
    let planID: String?, username: String?, password: String?, installationID: String?, operation: String?
}
enum TerminalClient {
    static let usage = """
    Gravity Linux Installer
      gravity-installer                         Open SwiftUI installer
      gravity-installer --version               Show installer version and build
      gravity-installer --tui              Interactive terminal installer
      gravity-installer --api              JSON Lines API on stdin/stdout
      gravity-installer --inspect          Print machine inspection as JSON
      gravity-installer --demo [--tui|--api]     Preview with no disk access
      gravity-installer --stage2 /Volumes/Gravity\\ Linux/Finish\\ Installation.app/Contents/Resources/stage2.json [--tui]
      gravity-installer --handoff-bundle DEST [--ipsw URL_OR_PATH]
      gravity-installer --fwextract SOURCE DEST  Rebuild saved firmware (optional: --board PROFILE_ID)
    Options: --resources PATH --developer|--no-developer
      --catalog URL_OR_PATH --repository URL_OR_PATH  Override CDN image sources
    Stage2 is automatic when launched from the installed recovery app.
    """
    static func prompt(_ text: String, default fallback: String? = nil) throws -> String {
        print(text + (fallback.map { " [\($0)]" } ?? "") + ": ", terminator: ""); fflush(stdout)
        guard let line = readLine() else { throw InstallerError("Input closed") }; return line.isEmpty ? (fallback ?? "") : line
    }
    static func choose<T>(_ items: [T], name: (T) -> String) throws -> T {
        guard !items.isEmpty else { throw InstallerError("There are no available choices") }
        for (i, item) in items.enumerated() { print("  \(i+1). \(name(item))") }
        while true {
            if let n = Int(try prompt("Choose", default: "1")), items.indices.contains(n-1) { return items[n-1] }
            print("Enter a number from 1 to \(items.count).")
        }
    }
    static func credentials(_ administrator: String) throws -> Credentials {
        let user = try prompt("macOS administrator username", default: administrator)
        guard isatty(STDIN_FILENO) != 0 else { throw InstallerError("Password entry requires a terminal. For automation, pass credentials through --api stdin.") }
        guard let password = getpass("macOS administrator password: ") else { throw InstallerError("Password entry cancelled") }
        let result = String(cString: password); memset(password, 0, strlen(password))
        return Credentials(username: user, password: result)
    }
    static func run(_ options: LaunchOptions) async throws {
        let output = TerminalOutput(api: options.api || options.inspect || options.handoff != nil)
        let engine = InstallerSession(configuration: options.configuration, events: { if !options.inspect { output.event($0) } })
        if options.api { await serve(engine, output: output); return }
        if let destination = options.handoff {
            try await engine.collectHandoffBundle(destination: destination, ipsw: options.handoffIPSW)
            output.printJSON(["status": "complete", "handoff": destination.path, "diskChanges": false]); return
        }
        if let (source, dest) = options.firmware { try await engine.rebuildFirmware(source: source, destination: dest, boardID: options.firmwareBoardID); return }
        if options.configuration.stage2URL != nil {
            let status = try await engine.stage2Status()
            if options.inspect { output.printJSON(try output.value(status)); return }
            print("Finish installing \(status.name)\n\(InstallStep.check1TR.help)")
            if status.complete { print("Installation is already complete.") }
            else {
                guard status.in1TR && status.paired && status.ready else { print(restartGuide(status.name)); throw InstallerError("Start the paired recovery in 1TR before finalizing") }
                guard try prompt("Type FINALIZE to continue") == "FINALIZE" else { return }
                let auth = options.configuration.demo ? Credentials(username: "demo", password: "demo") : try credentials("")
                try await engine.finalize(credentials: auth)
            }
            if try prompt("Restart now? y/N").lowercased() == "y" { try await engine.powerOff(restart: true) }; return
        }
        let info = try await engine.inspect()
        if options.inspect { output.printJSON(try output.value(info)); return }
        print("\nInstall Gravity Linux · \(info.board?.productNumber ?? info.boardProfileID ?? info.model)\n")
        if !info.existing.isEmpty {
            let os = try choose(info.existing, name: { $0.name })
            let action = try choose(os.canUninstall ? ["repair", "upgrade", "uninstall", "quit"] : ["repair", "upgrade", "quit"], name: { $0 })
            if action == "quit" { return }
            let plan = try await engine.planMaintenance(installationID: os.id, operation: action)
            for change in plan.changes { print("  • \(change)") }
            guard try prompt("Type \(action.uppercased()) to continue") == action.uppercased() else { return }
            try await engine.maintain(planID: plan.id, credentials: credentials(info.administrator))
            if action == "uninstall" { print("Gravity Linux was removed."); return }
            print(restartGuide(os.name))
        } else {
            print("Gravity Linux runs alongside macOS. Keep your Mac connected to power and the internet.")
            let target = try choose(info.targets, name: { "\($0.name) · up to \(sizeText($0.maximumBytes))" })
            let software = try choose(info.software, name: { "\($0.name) · requires \(sizeText($0.minimumBytes))" })
            let amount = try parseSize(prompt("Space for Gravity Linux", default: "\(min(target.maximumBytes, max(120_000_000_000, software.recommendedBytes)))B"))
            let name = try prompt("Startup volume name", default: "Gravity Linux")
            let plan = try await engine.plan(InstallSelection(targetID: target.id, softwareID: software.id, bytes: amount, name: name))
            print("\nReview and install")
            for change in plan.changes { print("  • \(change)") }
            guard try prompt("Type INSTALL to begin") == "INSTALL" else { return }
            let auth = options.configuration.demo ? Credentials(username: "demo", password: "demo") : try credentials(info.administrator)
            try await engine.install(planID: plan.id, credentials: auth)
            print(restartGuide(name))
        }
        if try prompt("Shut down now? y/N").lowercased() == "y" { try await engine.powerOff(restart: false) }
    }
    static func restartGuide(_ name: String) -> String {
        """
        One restart to finish:
          1. Shut down and wait 20 seconds.
          2. Hold your Mac’s power button continuously until “Loading startup options” appears.
          3. Choose \(name), then Continue, and finalize with your macOS administrator login.
        Keep these steps on your phone: \(GuideLinks.recovery.absoluteString)
        """
    }
    static func serve(_ engine: InstallerSession, output: TerminalOutput) async {
        output.printJSON(["type": "hello", "version": 1])
        var sessionCredentials: Credentials?
        defer { sessionCredentials = nil }
        while let line = readLine() {
            var id = ""
            do {
                let request = try JSONDecoder().decode(APIRequest.self, from: Data(line.utf8)); id = request.id
                func auth() throws -> Credentials {
                    if let user = request.username, let password = request.password { sessionCredentials = Credentials(username: user, password: password) }
                    guard let credentials = sessionCredentials else { throw InstallerError("username and password are required on stdin") }; return credentials
                }
                func planID() throws -> String { guard let id = request.planID else { throw InstallerError("planID is required") }; return id }
                let result: Any
                switch request.method {
                case "authorize": result = ["pid": try await engine.authorize(credentials: auth()), "authorized": true]
                case "privilegedSession": result = ["pid": try await engine.authorizationStatus()]
                case "checkBoardSupport": result = try output.value(await engine.checkBoardSupport())
                case "inspect": result = try output.value(await engine.inspect())
                case "plan": guard let selection = request.selection else { throw InstallerError("selection is required") }; result = try output.value(await engine.plan(selection))
                case "installReviewed": guard let plan = request.reviewedPlan else { throw InstallerError("reviewedPlan is required") }; try await engine.installReviewed(plan, credentials: auth()); result = ["status": "restartRequired"]
                case "maintainReviewed": guard let plan = request.reviewedMaintenance else { throw InstallerError("reviewedMaintenance is required") }; try await engine.maintainReviewed(plan, credentials: auth()); result = ["status": "done"]
                case "install": try await engine.install(planID: planID(), credentials: auth()); result = ["status": "restartRequired"]
                case "stage2Status": result = try output.value(await engine.stage2Status())
                case "finalize": try await engine.finalize(credentials: auth()); result = ["status": "complete"]
                case "planMaintenance": guard let installation = request.installationID, let operation = request.operation else { throw InstallerError("installationID and operation are required") }; result = try output.value(await engine.planMaintenance(installationID: installation, operation: operation))
                case "maintain": try await engine.maintain(planID: planID(), credentials: auth()); result = ["status": "done"]
                case "shutdown": try await engine.powerOff(restart: false); result = ["status": "done"]
                case "reboot": try await engine.powerOff(restart: true); result = ["status": "done"]
                default: throw InstallerError("Unknown API method")
                }
                output.printJSON(["type": "result", "version": 1, "id": id, "result": result])
                if ["install", "installReviewed", "maintain", "maintainReviewed", "finalize"].contains(request.method) { sessionCredentials = nil }
            } catch {
                var response: [String: Any] = ["type": "error", "version": 1, "id": id, "message": error.localizedDescription]
                if let issue = error as? BoardSupportError { response["boardSupport"] = try? output.value(issue) }
                output.printJSON(response)
            }
        }
    }
}
