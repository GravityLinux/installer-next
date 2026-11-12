// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
import GravityCore
@testable import GravityInstaller

@Test func embeddedRecoveryGUIAcceptsSystemLaunchArguments() throws {
    let resources = FileManager.default.temporaryDirectory.appendingPathComponent("gravity-recovery-launch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: resources) }
    let record = resources.appendingPathComponent("stage2.json")
    try Data("{}".utf8).write(to: record)
    // These are launch-argument examples, not a claim about the unavailable
    // machine's actual Recovery arguments. The marker still gets validated by
    // Stage2Context before any boot-policy operation.
    let launch = try LaunchOptions(["-psn_0_123", "-ApplePersistenceIgnoreState", "YES", "--gui"], preferences: DeveloperPreferences(), resourceDirectory: resources)
    #expect(launch.configuration.stage2URL == record)
    #expect(!launch.terminal && !launch.api && !launch.configuration.demo)
    for mode in ["--api", "--tui", "--inspect", "--version"] {
        #expect(throws: (any Error).self) { try LaunchOptions([mode, "--invalid-option"], preferences: DeveloperPreferences(), resourceDirectory: resources) }
    }
}

@Test func ordinaryInstallerLaunchesKeepStrictCommandLineValidation() throws {
    #expect(throws: (any Error).self) { try LaunchOptions(["--invalid-option"], preferences: DeveloperPreferences()) }
}
