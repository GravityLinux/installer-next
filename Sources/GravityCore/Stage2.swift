// SPDX-License-Identifier: GPL-2.0-only
import Foundation

struct SavedPartition: Codable, Sendable {
    let uuid: String, type: String, bytes: Int64
    init(_ p: DiskPartition) { uuid = p.uuid; type = p.type; bytes = p.size }
}
struct Stage2Record: Codable, Sendable {
    let version: Int
    let vgid: String, prebootUUID: String, name: String
    let macOSPartitionUUID: String
    var partitions: [SavedPartition]
    var ready: Bool
    var complete: Bool
    var managedLayout = true
    var boardProfileID: String? = nil
    var hardware: HardwareIdentity? = nil
    var developerMode: Bool? = nil
}
struct Stage2Context {
    let record: Stage2Record
    let configURL: URL
    let system: URL
    let board: BoardProfile
    var resources: URL { configURL.deletingLastPathComponent() }
    init(_ config: URL, boards: BoardRegistry = .builtIn, developer: Bool = false) throws {
        configURL = config.standardizedFileURL
        record = try JSONDecoder().decode(Stage2Record.self, from: Data(contentsOf: configURL))
        board = try boards.savedProfile(id: record.boardProfileID, hardware: record.hardware, developer: developer || record.developerMode == true)
        try require(record.version == 1 && UUID(uuidString: record.vgid) != nil && UUID(uuidString: record.prebootUUID) != nil, "Invalid stage2 volume identifiers")
        let resources = configURL.deletingLastPathComponent()
        try require(configURL.lastPathComponent == "stage2.json" && resources.lastPathComponent == "Resources" && resources.deletingLastPathComponent().lastPathComponent == "Contents", "Stage2 configuration must be inside the installed app bundle")
        system = configURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try require(fm.fileExists(atPath: resources.appending("boot.bin").path), "The installed boot object is missing; run Repair from macOS")
    }
    func status(commands: CommandRunning) throws -> String {
        String(decoding: try commands.run("/usr/bin/bputil", ["-d", "-v", record.vgid], input: nil), as: UTF8.self)
    }
    func validate(commands: CommandRunning) throws {
        try require(record.ready, "The first installation stage is incomplete; finalization cannot continue")
        let policy = try status(commands: commands)
        try require(policy.contains(": Paired"), "Start the recovery environment paired with \(record.name). Shut down and choose \(record.name) in startup options.")
        try require(MacSystem.environment(policy) == "one true recoveryOS", "Hold the power button continuously from power off until startup options appear. Finalization requires One True Recovery (1TR).")
    }
    func finalize(commands: CommandRunning, credentials: Credentials, events: EventSink) throws {
        events(InstallEvent(.check1TR)); try validate(commands: commands)
        try require(!credentials.username.isEmpty && !credentials.password.isEmpty, "Enter a macOS administrator login")
        events(InstallEvent(.securityPolicy))
        try commands.authenticated("/usr/bin/bputil", ["-nc", "-v", record.vgid], credentials: credentials)
        let isc = URL(fileURLWithPath: "/System/Volumes/iSCPreboot/\(record.vgid)")
        if fm.fileExists(atPath: isc.appending("boot").path) {
            events(InstallEvent(.externalPreboot))
            let disk = DiskManager(commands: commands); let preboot = try disk.mount(record.prebootUUID)
            try copy(preboot.appending("\(record.vgid)/var"), isc.appending("var"))
        }
        events(InstallEvent(.registerBoot))
        let args = board.boot.registration.arguments(bootObject: resources.appending("boot.bin"), system: system)
        try commands.authenticated("/usr/bin/kmutil", args, credentials: credentials)
        events(InstallEvent(.finish))
        _ = try commands.run("/sbin/mount", ["-u", "-w", system.path], input: nil)
        let media = system.appending(".IAPhysicalMedia")
        if fm.fileExists(atPath: media.path) { try copy(media, system.appending("IAPhysicalMedia-disabled.plist")); try fm.removeItem(at: media) }
        let disabled = system.appending("System/Library/CoreServices/SystemVersion-disabled.plist")
        if fm.fileExists(atPath: disabled.path) {
            try copy(disabled, system.appending("System/Library/CoreServices/SystemVersion.plist")); try fm.removeItem(at: disabled)
        }
        var finished = record; finished.complete = true
        try write(JSONEncoder().encode(finished), to: configURL)
        events(InstallEvent(.complete, fraction: 1))
    }
}
