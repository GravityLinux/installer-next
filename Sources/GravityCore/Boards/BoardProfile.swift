// SPDX-License-Identifier: GPL-2.0-only
import Foundation

public struct HardwareIdentity: Codable, Equatable, Sendable {
    public let deviceClass: String
    public let chipID: Int64
    public let boardID: Int64
    public init(deviceClass: String, chipID: Int64, boardID: Int64) {
        self.deviceClass = deviceClass.lowercased(); self.chipID = chipID; self.boardID = boardID
    }
    public var productNumber: String { deviceClass.hasSuffix("ap") ? String(deviceClass.dropLast(2)) : deviceClass }
}

public struct BoardPresentation: Codable, Sendable {
    /// Assigned from BoardProfile.id, never a separate marketing name.
    public internal(set) var productNumber = ""
    public let symbol: String
    public let status: String
    public let notes: String
    public let powerButtonHelp: String
    public let postInstallNote: String?
    public init(symbol: String = "desktopcomputer", status: String, notes: String, powerButtonHelp: String, postInstallNote: String? = nil) {
        self.symbol = symbol; self.status = status; self.notes = notes; self.powerButtonHelp = powerButtonHelp
        self.postInstallNote = postInstallNote
    }
}

public enum BoardAvailability: String, Codable, Sendable { case standard, developer }

public struct BoardStoragePolicy: Sendable {
    public static let defaultMacOSReserveBytes: Int64 = 2_000_000_000
    public let stubBytes: Int64
    public let macOSReserveBytes: Int64
    public let minimumLinuxBytes: Int64
    public init(stubBytes: Int64 = 2_500_000_000, macOSReserveBytes: Int64 = BoardStoragePolicy.defaultMacOSReserveBytes, minimumLinuxBytes: Int64 = 30_000_000_000) {
        self.stubBytes = alignDown(stubBytes); self.macOSReserveBytes = macOSReserveBytes; self.minimumLinuxBytes = minimumLinuxBytes
    }
}

public struct BootRegistration: Codable, Equatable, Sendable {
    public let alignment: Int
    public let entryPoint: UInt64
    public let lowestVirtualAddress: UInt64
    public init(alignment: Int = 65536, entryPoint: UInt64 = 2048, lowestVirtualAddress: UInt64 = 0) {
        self.alignment = alignment; self.entryPoint = entryPoint; self.lowestVirtualAddress = lowestVirtualAddress
    }
    func arguments(bootObject: URL, system: URL) -> [String] {
        ["configure-boot", "-c", bootObject.path, "--raw", "--entry-point", String(entryPoint), "--lowest-virtual-address", String(lowestVirtualAddress), "-v", system.path]
    }
}

public struct BoardBootAssets: Sendable {
    public let directory: String
    public let stage1: String
    public let registration: BootRegistration
    public init(directory: String = "", stage1: String = "m1n1.bin", registration: BootRegistration = BootRegistration()) {
        self.directory = directory; self.stage1 = stage1; self.registration = registration
    }
    func resource(_ name: String, in resources: URL) throws -> URL {
        for component in [directory, name] {
            try require(!component.hasPrefix("/") && !component.split(separator: "/").contains(".."), "Invalid board boot asset path")
        }
        return resources.appending("boot").appending(directory).appending(name)
    }
}

public enum RecoveryEncoding: Sendable {
    case dmg
    case aea(encryptedSHA256: String, key: String)
}

public struct RestoreProfile: Sendable {
    public let version: String
    public let url: URL
    public let member: String
    public let decodedSHA256: String
    public let encoding: RecoveryEncoding
    public let variant: String
    public let behavior: String
    public let restoreBundleFallback: String?
    public init(version: String, url: URL, member: String, decodedSHA256: String, encoding: RecoveryEncoding,
                variant: String = "macOS Customer", behavior: String = "Erase", restoreBundleFallback: String? = nil) {
        self.version = version; self.url = url; self.member = member; self.decodedSHA256 = decodedSHA256
        self.encoding = encoding; self.variant = variant; self.behavior = behavior; self.restoreBundleFallback = restoreBundleFallback
    }
    func selectIdentity(in manifest: [String: Any], hardware: HardwareIdentity) throws -> [String: Any] {
        let matches = array(manifest["BuildIdentities"]).filter {
            let info = dict($0["Info"])
            return string($0["ApBoardID"]).lowercased() == String(format: "0x%02llx", hardware.boardID)
                && string($0["ApChipID"]).lowercased() == String(format: "0x%04llx", hardware.chipID)
                && string(info["DeviceClass"]).lowercased() == hardware.deviceClass
                && string(info["RestoreBehavior"]) == behavior && string(info["Variant"]) == variant
        }
        try require(matches.count == 1, "Could not uniquely identify a restore build for this board")
        return matches[0]
    }
    func restoreBundlePath(bootcaches: [String: Any]) throws -> String {
        let declared = string(dict(bootcaches["bless2"])["RestoreBundlePath"])
        guard let path = declared.isEmpty ? restoreBundleFallback : declared else { throw InstallerError("Missing RestoreBundlePath for qualified restore \(version)") }
        try require(!path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains(".."), "Invalid restore bundle path")
        return path
    }
}

/// All policy choices for a supported board live here or in its firmware loader.
/// Core orchestration never switches on a device name, chip ID, or profile ID.
public struct BoardProfile: Sendable {
    public let id: String
    public let deviceClass: String
    public let chipID: Int64
    public let boardIDs: Set<Int64>?
    public let minimumMacOS: String
    public let restore: RestoreProfile
    public let firmwareMachine: String
    public let firmware: any BoardFirmwareLoading
    public let boot: BoardBootAssets
    public let storage: BoardStoragePolicy
    public let presentation: BoardPresentation
    public let installationModes: Set<InstallationMode>
    public let availability: BoardAvailability
    /// Compatibility with existing image metadata that predates board selectors.
    /// New boards require an explicit supported_boards/supported_devices match.
    public let acceptsUnscopedImages: Bool
    public init(id: String, deviceClass: String, chipID: Int64, boardIDs: Set<Int64>? = nil,
                minimumMacOS: String, restore: RestoreProfile, firmwareMachine: String,
                firmware: any BoardFirmwareLoading, boot: BoardBootAssets = BoardBootAssets(),
                storage: BoardStoragePolicy = BoardStoragePolicy(), presentation: BoardPresentation,
                installationModes: Set<InstallationMode> = [.linux, .uefi, .bootloader],
                availability: BoardAvailability = .standard, acceptsUnscopedImages: Bool = false) {
        self.id = id; self.deviceClass = deviceClass.lowercased(); self.chipID = chipID; self.boardIDs = boardIDs
        self.minimumMacOS = minimumMacOS; self.restore = restore; self.firmwareMachine = firmwareMachine
        self.firmware = firmware; self.boot = boot; self.storage = storage
        var presentation = presentation; presentation.productNumber = id; self.presentation = presentation
        self.installationModes = installationModes
        self.availability = availability
        self.acceptsUnscopedImages = acceptsUnscopedImages
    }
    public func matches(_ hardware: HardwareIdentity) -> Bool {
        hardware.deviceClass == deviceClass && hardware.chipID == chipID && (boardIDs?.contains(hardware.boardID) ?? true)
    }
    func validateDefinition() throws {
        for value in [id, firmwareMachine] {
            try require(!value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }, "Invalid board profile identifier")
        }
        try require(!deviceClass.isEmpty && chipID > 0 && boardIDs?.isEmpty != true, "Invalid hardware match in board profile \(id)")
        try require(!minimumMacOS.isEmpty && !restore.version.isEmpty && !restore.member.isEmpty, "Missing version or recovery member for \(id)")
        try require(storage.stubBytes > 0 && storage.macOSReserveBytes >= 0 && storage.minimumLinuxBytes >= 0, "Invalid storage policy for \(id)")
        let alignment = boot.registration.alignment
        try require(alignment > 0 && alignment <= 16 * 1024 * 1024 && alignment & (alignment - 1) == 0, "Boot object alignment must be a bounded power of two")
        try require(boot.registration.entryPoint >= boot.registration.lowestVirtualAddress, "Boot entry point precedes the lowest virtual address")
        try require(!installationModes.isEmpty, "Board \(id) has no supported installation modes")
        let sha = restore.decodedSHA256
        try require(sha.count == 64 && sha.allSatisfy { "0123456789abcdef".contains($0) }, "Invalid recovery SHA-256 for \(id)")
        if case let .aea(encrypted, key) = restore.encoding {
            try require(encrypted.count == 64 && encrypted.allSatisfy { "0123456789abcdef".contains($0) } && !key.isEmpty, "Invalid AEA qualification for \(id)")
        }
        _ = try boot.resource(boot.stage1, in: URL(fileURLWithPath: "/resources"))
    }
}
