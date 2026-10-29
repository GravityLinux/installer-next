// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

private struct ApplicationCommands: CommandRunning {
    var rejectStagedSignature = false
    func run(_ executable: String, _ arguments: [String], input: Data?) throws -> Data {
        try require(executable == "/usr/bin/codesign", "Unexpected deployment command")
        if rejectStagedSignature && arguments.last?.contains(".gravity-installer-update-") == true { throw InstallerError("Rejected fixture signature") }
        return Data()
    }
}
private func appFixture(_ root: URL, version: String = "0.1.0", release: String = "release-1") throws -> URL {
    let app = root.appending("Gravity Installer.app")
    try writePlist(["CFBundleIdentifier": InstallerBuildInfo.bundleIdentifier, "CFBundleExecutable": "gravity-installer", "CFBundleShortVersionString": version, "GravityRelease": release, "GravityRevision": "fixture-revision"], app.appending("Contents/Info.plist"))
    let binary = app.appending("Contents/MacOS/gravity-installer")
    try write(Data("#!/bin/sh\nexit 0\n".utf8), to: binary); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    try write(Data("#!/bin/sh\nexit 0\n".utf8), to: app.appending("Contents/Resources/launch.sh"))
    try write(Data(release.utf8), to: app.appending("Contents/Resources/boot/fixture.bin"))
    return app
}
private func distribution(_ app: URL, channel: String = "stable") -> InstallerDistribution {
    InstallerDistribution(installationPath: app.path, channel: channel, installerBaseURL: URL(string: "https://downloads.example.test/installer")!,
        latestURL: URL(string: "https://downloads.example.test/installer/latest")!, catalogURL: URL(string: "https://downloads.example.test/installer/installer_data.json")!, repositoryURL: URL(string: "https://downloads.example.test")!)
}
@Test func appInstallsPersistentlyAndSurvivesDownloadRemoval() throws {
    let temp = try TemporaryDirectory(), source = try appFixture(temp.url.appending("download")), destination = temp.url.appending("Applications/Gravity Installer.app")
    let result = try InstallerApplication.install(source: source, destination: destination, expectedRelease: "release-1", distribution: distribution(destination), commands: ApplicationCommands())
    #expect(result.status == "installed" && result.build.version == "0.1.0")
    try fm.removeItem(at: source.deletingLastPathComponent())
    #expect(try InstallerBuildInfo.read(destination).release == "release-1")
    #expect(try InstallerDistribution.read(from: destination) == distribution(destination))
    let installedLock = try InstallerApplicationLock.acquireIfInstalled(app: destination)
    let lock = try #require(installedLock); withExtendedLifetime(lock) {}
}
@Test func installerCanPersistWithoutHardcodedOSDownloadEndpoints() throws {
    let temp = try TemporaryDirectory(), source = try appFixture(temp.url.appending("download")), destination = temp.url.appending("Applications/Gravity Installer.app")
    let config = EngineConfiguration(resourceDirectory: temp.url)
    #expect(config.catalogURL == nil && config.repositoryURL == nil)
    let distribution = InstallerDistribution(installationPath: destination.path, channel: "local",
        installerBaseURL: URL(string: "http://localhost:5050")!, latestURL: URL(string: "http://localhost:5050/latest")!)
    _ = try InstallerApplication.install(source: source, destination: destination, expectedRelease: "release-1", distribution: distribution, commands: ApplicationCommands())
    let saved = try InstallerDistribution.read(from: destination)
    #expect(saved?.catalogURL == nil && saved?.repositoryURL == nil && saved == distribution)
}
@Test func executableSignatureSurvivesDeploymentAndRecoveryResourcesButRejectsTampering() throws {
    let temp = try TemporaryDirectory(), source = try appFixture(temp.url.appending("download")), destination = temp.url.appending("Applications/Gravity Installer.app")
    let commands = SystemCommands(), code = temp.url.appending("main.c"), signed = temp.url.appending("signed-installer")
    try write(Data("int main(void) { return 0; }\n".utf8), to: code)
    _ = try commands.run("/usr/bin/xcrun", ["clang", "-arch", "arm64", code.path, "-o", signed.path], input: nil)
    _ = try commands.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", InstallerBuildInfo.bundleIdentifier, signed.path], input: nil)
    let executable = source.appending("Contents/MacOS/gravity-installer")
    try write(Data(contentsOf: signed), to: executable)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let result = try InstallerApplication.install(source: source, destination: destination, expectedRelease: "release-1", distribution: distribution(destination), commands: commands)
    #expect(result.status == "installed")
    try write(Data("{}\n".utf8), to: destination.appending("Contents/Resources/stage2.json"))
    try write(Data("boot object".utf8), to: destination.appending("Contents/Resources/boot.bin"))
    let installed = destination.appending("Contents/MacOS/gravity-installer")
    _ = try commands.run("/usr/bin/codesign", ["--verify", "--strict", "--ignore-resources", installed.path], input: nil)
    var tampered = try Data(contentsOf: installed); tampered[4096] ^= 1
    try write(tampered, to: installed)
    #expect(throws: (any Error).self) { try commands.run("/usr/bin/codesign", ["--verify", "--strict", "--ignore-resources", installed.path], input: nil) }
}
@Test func updatesReplaceTheWholeAppAndSkipCurrentVersions() throws {
    let temp = try TemporaryDirectory(), destination = temp.url.appending("Applications/Gravity Installer.app")
    let first = try appFixture(temp.url.appending("v1")), second = try appFixture(temp.url.appending("v2"), version: "0.2.0", release: "release-2")
    _ = try InstallerApplication.install(source: first, destination: destination, expectedRelease: "release-1", distribution: distribution(destination), commands: ApplicationCommands())
    try write(Data("obsolete".utf8), to: destination.appending("Contents/Resources/obsolete"))
    let updated = try InstallerApplication.install(source: second, destination: destination, expectedRelease: "release-2", distribution: distribution(destination), commands: ApplicationCommands())
    #expect(updated.status == "updated" && updated.build.version == "0.2.0")
    #expect(!fm.fileExists(atPath: destination.appending("Contents/Resources/obsolete").path))
    #expect(try String(contentsOf: destination.appending("Contents/Resources/boot/fixture.bin")) == "release-2")
    let current = try InstallerApplication.install(source: second, destination: destination, expectedRelease: "release-2", distribution: distribution(destination), commands: ApplicationCommands())
    #expect(current.status == "current")
    let older = try InstallerApplication.install(source: first, destination: destination, expectedRelease: "release-1", distribution: distribution(destination), commands: ApplicationCommands())
    #expect(older.status == "newerInstalled" && older.build.version == "0.2.0")
    let reinstall = try InstallerApplication.install(source: first, destination: destination, expectedRelease: "release-1", distribution: distribution(destination), force: true, commands: ApplicationCommands())
    #expect(reinstall.status == "updated" && reinstall.build.version == "0.1.0")
}
@Test func runningAppBlocksUpdatesButAllowsCurrentVersionChecks() throws {
    let temp = try TemporaryDirectory(), destination = temp.url.appending("Applications/Gravity Installer.app")
    let first = try appFixture(temp.url.appending("v1")), second = try appFixture(temp.url.appending("v2"), version: "0.2.0", release: "release-2")
    _ = try InstallerApplication.install(source: first, destination: destination, expectedRelease: "release-1", distribution: distribution(destination), commands: ApplicationCommands())
    let active = try InstallerApplicationLock(app: destination, exclusive: false)
    defer { withExtendedLifetime(active) {} }
    #expect(throws: (any Error).self) { try InstallerApplication.install(source: second, destination: destination, expectedRelease: "release-2", distribution: distribution(destination), commands: ApplicationCommands()) }
    #expect(try InstallerBuildInfo.read(destination).release == "release-1")
    #expect(try InstallerApplication.install(source: first, destination: destination, expectedRelease: "release-1", distribution: distribution(destination), commands: ApplicationCommands()).status == "current")
}
@Test func failedUpdateLeavesOldAppUsableAndRemovesItsStage() throws {
    let temp = try TemporaryDirectory(), destination = temp.url.appending("Applications/Gravity Installer.app")
    let first = try appFixture(temp.url.appending("v1")), second = try appFixture(temp.url.appending("v2"), version: "0.2.0", release: "release-2")
    _ = try InstallerApplication.install(source: first, destination: destination, expectedRelease: "release-1", distribution: distribution(destination), commands: ApplicationCommands())
    #expect(throws: (any Error).self) { try InstallerApplication.install(source: second, destination: destination, expectedRelease: "release-2", distribution: distribution(destination), commands: ApplicationCommands(rejectStagedSignature: true)) }
    #expect(try InstallerBuildInfo.read(destination).release == "release-1")
    #expect(try fm.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).allSatisfy { !$0.hasPrefix(".gravity-installer-update-") })
}
@Test func installerRejectsUnrelatedAppsWrongReleasesAndRecoveryCopies() throws {
    let temp = try TemporaryDirectory(), source = try appFixture(temp.url.appending("download")), destination = temp.url.appending("Applications/Gravity Installer.app")
    #expect(throws: (any Error).self) { try InstallerApplication.install(source: source, destination: destination, expectedRelease: "another-release", distribution: distribution(destination), commands: ApplicationCommands()) }
    try writePlist(["CFBundleIdentifier": "another.application"], destination.appending("Contents/Info.plist"))
    #expect(throws: (any Error).self) { try InstallerApplication.install(source: source, destination: destination, expectedRelease: "release-1", distribution: distribution(destination), force: true, commands: ApplicationCommands()) }
    try fm.removeItem(at: destination)
    try write(Data("{}".utf8), to: source.appending("Contents/Resources/stage2.json"))
    #expect(throws: (any Error).self) { try InstallerApplication.install(source: source, destination: destination, expectedRelease: "release-1", distribution: distribution(destination), commands: ApplicationCommands()) }
}
