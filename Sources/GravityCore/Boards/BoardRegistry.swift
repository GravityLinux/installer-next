// SPDX-License-Identifier: GPL-2.0-only
import Foundation

public struct BoardRegistry: Sendable {
    public let profiles: [BoardProfile]
    private let legacyProfileID: String?
    public init(profiles: [BoardProfile], legacyProfileID: String? = nil) throws {
        try require(Set(profiles.map(\.id)).count == profiles.count, "Duplicate board profile ID")
        for profile in profiles { try profile.validateDefinition() }
        for (i, profile) in profiles.enumerated() {
            for other in profiles.dropFirst(i + 1) where profile.deviceClass == other.deviceClass && profile.chipID == other.chipID {
                let overlap = profile.boardIDs == nil || other.boardIDs == nil || !profile.boardIDs!.isDisjoint(with: other.boardIDs!)
                try require(!overlap, "Ambiguous hardware matches for board profiles \(profile.id) and \(other.id)")
            }
        }
        if let legacyProfileID { try require(profiles.contains { $0.id == legacyProfileID }, "Unknown legacy board profile") }
        self.profiles = profiles; self.legacyProfileID = legacyProfileID
    }
    public func availableProfiles(developer: Bool = false) -> [BoardProfile] {
        profiles.filter { developer || $0.availability == .standard }
    }
    public func resolve(_ hardware: HardwareIdentity, developer: Bool = false) throws -> BoardProfile {
        let matches = profiles.filter { $0.matches(hardware) }
        guard matches.count == 1 else {
            throw BoardSupportError(reason: .unsupported, productNumber: hardware.productNumber, hardware: hardware,
                supportedBoards: availableProfiles(developer: developer).map(\.id).sorted())
        }
        return try authorize(matches[0], hardware: hardware, developer: developer)
    }
    public func profile(id: String, developer: Bool = false) throws -> BoardProfile {
        guard let profile = profiles.first(where: { $0.id == id }) else { throw InstallerError("Unknown saved board profile: \(id)") }
        return try authorize(profile, hardware: nil, developer: developer)
    }
    private func authorize(_ profile: BoardProfile, hardware: HardwareIdentity?, developer: Bool) throws -> BoardProfile {
        if profile.availability == .developer && !developer {
            throw BoardSupportError(reason: .developerRequired, productNumber: profile.id, hardware: hardware,
                supportedBoards: availableProfiles().map(\.id).sorted())
        }
        return profile
    }
    func savedProfile(id: String?, hardware: HardwareIdentity? = nil, developer: Bool = false) throws -> BoardProfile {
        guard let id = id ?? legacyProfileID else { throw InstallerError("This older installation or firmware archive has no board profile. Specify its board explicitly.") }
        let profile = try self.profile(id: id, developer: developer)
        if let hardware { try require(profile.matches(hardware), "Saved hardware identity does not match board profile \(id)") }
        return profile
    }
    // Profiles/*.swift is discovered automatically by the SwiftPM build plugin.
    // The explicit legacy mapping applies only to artifacts from the M4-only installer.
    public static let builtIn = try! BoardRegistry(profiles: DiscoveredBoards.profiles, legacyProfileID: "j773g")
}
