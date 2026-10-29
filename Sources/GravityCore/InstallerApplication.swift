// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CInstallerSupport

/// Installer releases are independent of the Linux/Apple firmware versions.
public struct InstallerBuildInfo: Codable, Equatable, Sendable {
    public let version: String
    public let release: String
    public let revision: String
    public static let bundleIdentifier = "org.gravitylinux.installer"
    public init(version: String, release: String, revision: String) {
        self.version = version; self.release = release; self.revision = revision
    }
    public static var current: InstallerBuildInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return InstallerBuildInfo(version: string(info["CFBundleShortVersionString"]).nilIfEmpty ?? "development",
            release: string(info["GravityRelease"]).nilIfEmpty ?? "unbundled", revision: string(info["GravityRevision"]).nilIfEmpty ?? "unknown")
    }
    static func read(_ app: URL) throws -> InstallerBuildInfo {
        let info = try plist(app.appending("Contents/Info.plist"))
        try require(string(info["CFBundleIdentifier"]) == bundleIdentifier && string(info["CFBundleExecutable"]) == "gravity-installer", "The package is not a Gravity Installer app")
        try require(info["GravityDemo"] as? Bool != true, "Preview apps cannot be installed as production installers")
        let build = InstallerBuildInfo(version: string(info["CFBundleShortVersionString"]), release: string(info["GravityRelease"]), revision: string(info["GravityRevision"]))
        let components = build.version.split(separator: ".", omittingEmptySubsequences: false)
        try require(components.count == 3 && components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) && UInt32($0) != nil }, "Invalid installer version in the app bundle")
        try require(!build.release.isEmpty && build.release.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }, "Invalid installer release identifier")
        return build
    }
    public var description: String { "Gravity Installer \(version) (\(release), \(revision.prefix(12)))" }
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

/// Saved inside the persistent app so Finder launches use the same channel and
/// endpoints as the bootstrap. No temporary download paths are stored here.
public struct InstallerDistribution: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let installationPath: String
    public let channel: String
    public let installerBaseURL: URL
    public let latestURL: URL
    public let catalogURL: URL
    public let repositoryURL: URL
    public init(installationPath: String, channel: String, installerBaseURL: URL, latestURL: URL, catalogURL: URL, repositoryURL: URL) {
        schemaVersion = 1; self.installationPath = installationPath; self.channel = channel
        self.installerBaseURL = installerBaseURL; self.latestURL = latestURL; self.catalogURL = catalogURL; self.repositoryURL = repositoryURL
    }
    public static func location(in app: URL) -> URL { app.appending("Contents/Resources/installation.json") }
    public static func read(from app: URL) throws -> InstallerDistribution? {
        let file = location(in: app)
        if !fm.fileExists(atPath: file.path) { return nil }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        try value.validate(); return value
    }
    func validate() throws {
        try require(schemaVersion == 1 && installationPath.hasPrefix("/") && URL(fileURLWithPath: installationPath).pathExtension == "app", "Invalid installer installation record")
        try require(["stable", "development", "local"].contains(channel), "Unknown installer release channel")
        for url in [installerBaseURL, latestURL, catalogURL, repositoryURL] {
            try require(url.isFileURL || url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")), "Installer endpoints require HTTPS")
        }
    }
}

/// Shared for a whole GUI/TUI/API process, exclusive for replacement. The lock
/// lives beside the app, so atomically swapping the bundle cannot replace it.
public final class InstallerApplicationLock {
    private let descriptor: Int32
    public init(app: URL, exclusive: Bool, create: Bool = false) throws {
        let path = app.deletingLastPathComponent().appending(".gravity-installer-\(Data(app.standardizedFileURL.path.utf8).sha256.prefix(16)).lock")
        descriptor = open(path.path, (create ? O_RDWR | O_CREAT : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW, 0o644)
        try require(descriptor >= 0, "Could not open the installed app's update lock. Run the bootstrap again to repair the app.")
        if create { _ = fchmod(descriptor, 0o644) }
        if flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
            close(descriptor)
            throw InstallerError(exclusive ? "Quit Gravity Installer before updating it. An installation or repair may still be running." : "Gravity Installer is being updated. Open it again when the update finishes.")
        }
    }
    public static func acquireIfInstalled(app: URL?) throws -> InstallerApplicationLock? {
        guard let app, let distribution = try InstallerDistribution.read(from: app), URL(fileURLWithPath: distribution.installationPath).standardizedFileURL == app.standardizedFileURL else { return nil }
        return try InstallerApplicationLock(app: app, exclusive: false)
    }
    deinit { _ = flock(descriptor, LOCK_UN); close(descriptor) }
}

public struct InstallerDeploymentResult: Codable, Sendable {
    public let status: String
    public let path: String
    public let build: InstallerBuildInfo
}
public enum InstallerApplication {
    public static func install(source: URL, destination: URL, expectedRelease: String, distribution: InstallerDistribution,
                               force: Bool = false, commands: CommandRunning = SystemCommands()) throws -> InstallerDeploymentResult {
        let source = source.standardizedFileURL, destination = destination.standardizedFileURL
        try distribution.validate()
        try require(destination.pathExtension == "app" && destination.path == URL(fileURLWithPath: distribution.installationPath).standardizedFileURL.path && source != destination, "Invalid installer destination")
        try require(!fm.fileExists(atPath: source.appending("Contents/Resources/stage2.json").path), "A recovery copy cannot replace the installed maintenance app")
        let build = try InstallerBuildInfo.read(source)
        try require(build.release == expectedRelease, "Downloaded installer release does not match latest")
        try validateContents(source)
        _ = try commands.run("/usr/bin/codesign", ["--verify", "--strict", executable(in: source).path], input: nil)
        let parent = destination.deletingLastPathComponent(); try mkdir(parent)
        try validateDestination(destination)
        if let result = try unchanged(destination, build: build, distribution: distribution, force: force, commands: commands) { return result }
        let lock = try InstallerApplicationLock(app: destination, exclusive: true, create: true)
        defer { withExtendedLifetime(lock) {} }
        try validateDestination(destination)
        if let result = try unchanged(destination, build: build, distribution: distribution, force: force, commands: commands) { return result }
        let stage = parent.appending(".gravity-installer-update-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: stage) }
        try fm.copyItem(at: source, to: stage)
        try write(JSONEncoder().encode(distribution), to: InstallerDistribution.location(in: stage))
        try securePermissions(stage)
        _ = try commands.run("/usr/bin/codesign", ["--verify", "--strict", executable(in: stage).path], input: nil)
        let replacing = fm.fileExists(atPath: destination.path)
        if replacing {
            let result = stage.path.withCString { from in destination.path.withCString { gravity_swap_paths(from, $0) } }
            try require(result == 0, "Could not atomically update Gravity Installer (errno \(errno)); the previous app was kept")
        } else { try fm.moveItem(at: stage, to: destination) }
        return InstallerDeploymentResult(status: replacing ? "updated" : "installed", path: destination.path, build: build)
    }
    private static func executable(in app: URL) -> URL { app.appending("Contents/MacOS/gravity-installer") }
    private static func unchanged(_ app: URL, build: InstallerBuildInfo, distribution: InstallerDistribution, force: Bool, commands: CommandRunning) throws -> InstallerDeploymentResult? {
        guard !force, let current = try? InstallerBuildInfo.read(app) else { return nil }
        if current.version.compare(build.version, options: .numeric) == .orderedDescending {
            return InstallerDeploymentResult(status: "newerInstalled", path: app.path, build: current)
        }
        if current == build, try InstallerDistribution.read(from: app) == distribution,
           (try? commands.run("/usr/bin/codesign", ["--verify", "--strict", executable(in: app).path], input: nil)) != nil {
            return InstallerDeploymentResult(status: "current", path: app.path, build: current)
        }
        return nil
    }
    private static func validateDestination(_ app: URL) throws {
        if (try? fm.attributesOfItem(atPath: app.path)[.type] as? FileAttributeType) == .typeSymbolicLink { throw InstallerError("The installer destination must not be a symlink") }
        if fm.fileExists(atPath: app.path) {
            let info = try plist(app.appending("Contents/Info.plist"))
            try require(string(info["CFBundleIdentifier"]) == InstallerBuildInfo.bundleIdentifier, "Another application occupies the installer destination")
        }
    }
    private static func validateContents(_ app: URL) throws {
        guard let entries = fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { throw InstallerError("Could not inspect the installer bundle") }
        for case let entry as URL in entries {
            if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                let target = try fm.destinationOfSymbolicLink(atPath: entry.path)
                try require(!target.hasPrefix("/") && entry.resolvingSymlinksInPath().path.hasPrefix(app.resolvingSymlinksInPath().path + "/"), "An installer bundle symlink escapes its resources")
            }
        }
        try require(fm.isExecutableFile(atPath: executable(in: app).path) && fm.fileExists(atPath: app.appending("Contents/Resources/launch.sh").path), "The installer bundle is incomplete")
    }
    private static func securePermissions(_ app: URL) throws {
        let entries = fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey])
        for entry in [app] + (entries?.allObjects as? [URL] ?? []) {
            if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { continue }
            let mode = int(try fm.attributesOfItem(atPath: entry.path)[.posixPermissions]) & ~0o022
            try fm.setAttributes([.posixPermissions: mode, .ownerAccountID: geteuid(), .groupOwnerAccountID: getegid()], ofItemAtPath: entry.path)
        }
    }
}
