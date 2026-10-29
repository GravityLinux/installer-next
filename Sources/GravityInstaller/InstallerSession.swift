// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import GravityCore
import CInstallerSupport

/// One GUI/TUI/API session. Read-only planning stays in the caller; the first
/// committed operation starts a private root process using the credentials
/// entered after Review. That process stays alive through completion/power-off.
actor InstallerSession {
    let engine: InstallerEngine
    private let configuration: EngineConfiguration
    private let events: EventSink
    private var privileged: PrivilegedProcess?
    private var plans: [String: InstallPlan] = [:]
    private var maintenance: [String: MaintenancePlan] = [:]
    init(configuration: EngineConfiguration, events: @escaping EventSink = { _ in }) {
        self.configuration = configuration; self.events = events
        engine = InstallerEngine(configuration: configuration, events: events)
    }
    func checkBoardSupport() async throws -> BoardPresentation { try await engine.checkBoardSupport() }
    func inspect() async throws -> Inspection { try await engine.inspect() }
    func stage2Status() async throws -> Stage2Status { try await engine.stage2Status() }
    func plan(_ selection: InstallSelection) async throws -> InstallPlan {
        let plan = try await engine.plan(selection); plans = [plan.id: plan]; return plan
    }
    func planMaintenance(installationID: String, operation: String) async throws -> MaintenancePlan {
        let plan = try await engine.planMaintenance(installationID: installationID, operation: operation); maintenance = [plan.id: plan]; return plan
    }
    private var local: Bool { geteuid() == 0 || configuration.demo }
    private func connection(_ credentials: Credentials) throws -> PrivilegedProcess {
        if let privileged { return privileged }
        let process = try PrivilegedProcess(configuration: configuration, credentials: credentials, events: events)
        privileged = process; return process
    }
    /// Explicit API authorization for clients that are ready to commit. The
    /// graphical client only creates this session from its final password sheet.
    func authorize(credentials: Credentials) throws -> Int32 {
        if local { return getpid() }
        let result = try connection(credentials).request(method: "privilegedSession") as? [String: Any]
        guard let pid = result?["pid"] as? Int32 else { throw InstallerError("The privileged session could not be verified.") }; return pid
    }
    func authorizationStatus() throws -> Int32 {
        if local { return getpid() }
        guard let privileged, let result = try privileged.request(method: "privilegedSession") as? [String: Any], let pid = result["pid"] as? Int32 else { throw InstallerError("Administrator authorization is required.") }; return pid
    }
    func install(planID: String, credentials: Credentials) async throws {
        if local { try await engine.install(planID: planID, credentials: credentials); return }
        guard let plan = plans[planID] else { throw InstallerError("Review an installation plan first") }
        _ = try connection(credentials).request(method: "installReviewed", fields: ["reviewedPlan": try json(plan)], credentials: credentials)
        plans = [:]
    }
    func maintain(planID: String, credentials: Credentials) async throws {
        if local { try await engine.maintain(planID: planID, credentials: credentials); return }
        guard let plan = maintenance[planID] else { throw InstallerError("Review a maintenance plan first") }
        _ = try connection(credentials).request(method: "maintainReviewed", fields: ["reviewedMaintenance": try json(plan)], credentials: credentials)
        maintenance = [:]
    }
    func installReviewed(_ plan: InstallPlan, credentials: Credentials) async throws { try await engine.installReviewed(plan, credentials: credentials) }
    func maintainReviewed(_ plan: MaintenancePlan, credentials: Credentials) async throws { try await engine.maintainReviewed(plan, credentials: credentials) }
    func finalize(credentials: Credentials) async throws {
        if local { try await engine.finalize(credentials: credentials); return }
        _ = try connection(credentials).request(method: "finalize", credentials: credentials)
    }
    func powerOff(restart: Bool) async throws {
        if local { try await engine.powerOff(restart: restart); return }
        guard let privileged else { throw InstallerError("Restart or shut down from the Apple menu.") }
        _ = try privileged.request(method: restart ? "reboot" : "shutdown")
    }
    func collectHandoffBundle(destination: URL, ipsw: URL?) async throws { try await engine.collectHandoffBundle(destination: destination, ipsw: ipsw) }
    func rebuildFirmware(source: URL, destination: URL, boardID: String?) async throws { try await engine.rebuildFirmware(source: source, destination: destination, boardID: boardID) }
    private func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
}

private final class PrivilegedProcess {
    private let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
    private var buffer = Data(), diagnostic = Data()
    private let events: EventSink
    init(configuration: EngineConfiguration, credentials: Credentials, events: @escaping EventSink) throws {
        self.events = events
        guard credentials.username == NSUserName() else { throw InstallerError("Use the administrator account currently logged in to macOS: \(NSUserName()).") }
        guard !credentials.password.isEmpty && !credentials.password.contains("\n") && !credentials.password.contains("\0") else { throw InstallerError("Enter your macOS administrator password.") }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        var arguments = ["-S", "-k", "-p", "", "--", CommandLine.arguments[0], "--api", "--resources", configuration.resourceDirectory.path]
        arguments.append(configuration.developer ? "--developer" : "--no-developer")
        if let stage2 = configuration.stage2URL { arguments += ["--stage2", stage2.path] }
        process.arguments = arguments; process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        do {
            try input.fileHandleForWriting.write(contentsOf: Data((credentials.password + "\n").utf8))
            let hello = try next(deadline: Date().addingTimeInterval(30))
            guard hello["type"] as? String == "hello" else { throw InstallerError("The privileged installer did not start correctly.") }
        } catch { if process.isRunning { process.terminate() }; throw error }
    }
    deinit { try? input.fileHandleForWriting.close() }
    func request(method: String, fields: [String: Any] = [:], credentials: Credentials? = nil) throws -> Any {
        let id = UUID().uuidString
        var request = fields; request["id"] = id; request["method"] = method
        if let credentials { request["username"] = credentials.username; request["password"] = credentials.password }
        let payload = try JSONSerialization.data(withJSONObject: request) + Data([10])
        try input.fileHandleForWriting.write(contentsOf: payload)
        while true {
            let frame = try next()
            if frame["type"] as? String == "event", let name = frame["step"] as? String, let step = InstallStep(rawValue: name) {
                events(InstallEvent(step, fraction: frame["fraction"] as? Double, detail: frame["detail"] as? String, help: frame["help"] as? String, title: frame["title"] as? String)); continue
            }
            guard frame["id"] as? String == id else { continue }
            if frame["type"] as? String == "error" { throw InstallerError(frame["message"] as? String ?? "The privileged installer failed.") }
            return frame["result"] ?? [:]
        }
    }
    private func next(deadline: Date? = nil) throws -> [String: Any] {
        while true {
            if let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                guard let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw InstallerError("Invalid privileged installer response.") }; return frame
            }
            if gravity_poll_readable(errors.fileHandleForReading.fileDescriptor, 0) > 0 {
                diagnostic.append(errors.fileHandleForReading.availableData)
                if diagnostic.count > 8192 { diagnostic = Data(diagnostic.suffix(8192)) }
                let text = String(decoding: diagnostic, as: UTF8.self)
                if text.contains("Sorry, try again") || text.contains("not in the sudoers") || text.contains("not allowed to execute") { throw InstallerError("macOS could not authorize this administrator login. Check your password and try again.") }
            }
            if let deadline, Date() >= deadline { throw InstallerError("macOS authorization timed out. Try your administrator login again.") }
            if gravity_poll_readable(output.fileHandleForReading.fileDescriptor, 100) > 0 {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { throw InstallerError("The privileged installer session ended. " + String(decoding: diagnostic, as: UTF8.self)) }
                buffer.append(data)
                if buffer.count > 1_000_000 { throw InstallerError("Privileged installer response exceeds its size limit.") }
            } else if !process.isRunning { throw InstallerError("The privileged installer session ended. " + String(decoding: diagnostic, as: UTF8.self)) }
        }
    }
}
