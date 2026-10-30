// SPDX-License-Identifier: GPL-2.0-only
import Foundation

public enum InstallStep: String, Codable, CaseIterable, Sendable {
    case inspecting, metadata, package, stage1, ipsw, validateRecovery, decodeRecovery, verifyRecovery
    case resize, createStub, volumes, systemVolume, dataVolume, preboot, bootability, restoreFirmware, administrators
    case recoveryVolume, compressRecovery, stage2App, partition, format, calibration, wifi, bluetooth, multitouch, kernel, boardFirmware, firmwareArchive
    case systemImage, systemFiles, extras, bootObject, installerData, reducedSecurity, defaultBoot, restart
    case check1TR, externalPreboot, securityPolicy, registerBoot, finish, complete, repair, uninstall
    public var title: String {
        switch self {
        case .inspecting: return "Checking this Mac"
        case .metadata: return "Loading available software"
        case .package: return "Opening the Gravity Linux package"
        case .stage1: return "Downloading the startup bootloader"
        case .ipsw: return "Opening Apple restore firmware"
        case .validateRecovery: return "Checking recovery compatibility"
        case .decodeRecovery: return "Decoding recovery"
        case .verifyRecovery: return "Verifying recovery"
        case .resize: return "Making room for Gravity Linux"
        case .createStub: return "Creating the startup partition"
        case .volumes: return "Preparing APFS volumes"
        case .systemVolume: return "Setting up the System volume"
        case .dataVolume: return "Setting up the Data volume"
        case .preboot: return "Setting up Preboot"
        case .bootability: return "Installing Apple bootability tools"
        case .restoreFirmware: return "Installing Apple restore firmware"
        case .administrators: return "Preparing administrator authentication"
        case .recoveryVolume: return "Installing recovery"
        case .compressRecovery: return "Compressing recovery"
        case .stage2App: return "Preparing the recovery installer"
        case .partition: return "Creating Linux partitions"
        case .format: return "Formatting the EFI partition"
        case .calibration: return "Collecting this Mac’s radio calibration"
        case .wifi: return "Collecting Wi-Fi firmware"
        case .bluetooth: return "Collecting Bluetooth firmware"
        case .multitouch: return "Collecting multitouch firmware"
        case .kernel: return "Collecting USB controller firmware"
        case .boardFirmware: return "Collecting board firmware"
        case .firmwareArchive: return "Saving firmware for future updates"
        case .systemImage: return "Writing the Linux system image"
        case .systemFiles: return "Copying system files"
        case .extras: return "Downloading additional files"
        case .bootObject: return "Building the startup boot object"
        case .installerData: return "Saving installation information"
        case .reducedSecurity: return "Preparing recovery startup"
        case .defaultBoot: return "Selecting Gravity Linux for startup"
        case .restart: return "Ready for startup options"
        case .check1TR: return "Checking startup options"
        case .externalPreboot: return "Preparing external Preboot authentication"
        case .securityPolicy: return "Authorizing the Linux startup policy"
        case .registerBoot: return "Registering Gravity Linux"
        case .finish: return "Finishing installation"
        case .complete: return "Gravity Linux is installed"
        case .repair: return "Repairing startup files"
        case .uninstall: return "Removing Gravity Linux"
        }
    }
    public var help: String {
        switch self {
        case .inspecting: return "Checking the model, macOS version, boot environment, and partition layout."
        case .metadata: return "Checking the CDN for available installation images compatible with this Mac."
        case .package: return "Only the needed parts of the software archive are downloaded."
        case .stage1: return "Fetching stage1 from the selected CDN and checking its SHA-256 before changing partitions."
        case .ipsw: return "Apple restore firmware provides the boot files and recovery environment this Mac needs."
        case .validateRecovery: return "Recovery and the firmware required by this board are checked before any partition changes."
        case .decodeRecovery: return "macOS is decoding the Apple recovery image. This needs at least 4 GiB of temporary free space."
        case .verifyRecovery: return "Checking the qualified recovery SHA-256 pins and Apple disk image checksums."
        case .resize: return "Apple’s APFS tool is shrinking macOS. Your Mac may briefly stop responding; let it finish."
        case .createStub, .volumes: return "Creating a separate Apple boot environment for Gravity Linux. Keep your Mac connected to power."
        case .systemVolume, .dataVolume: return "These small APFS volumes let Apple’s startup system recognize Gravity Linux."
        case .preboot, .bootability, .restoreFirmware: return "Copying the boot files for this exact Mac and Apple restore build."
        case .administrators: return "Copying macOS machine-owner records so Apple can authenticate startup changes."
        case .recoveryVolume: return "Installing a recovery environment paired with Gravity Linux."
        case .compressRecovery: return "Using APFS transparent LZFSE compression, then reading back the image to verify it."
        case .stage2App: return "Saving this same installer on the new startup volume so it can finish offline in recovery."
        case .partition, .format: return "Preparing the EFI and Linux partitions inside the space you reviewed."
        case .calibration: return "Saving factory calibration from this Mac, bound to its own Wi-Fi and Bluetooth addresses."
        case .wifi: return "Collecting the Wi-Fi firmware and configuration required by this board."
        case .bluetooth: return "Collecting the Bluetooth firmware and configuration required by this board."
        case .multitouch: return "Converting any multitouch firmware provided by the selected restore identity."
        case .kernel: return "Extracting this board’s required firmware from Apple’s kernel cache."
        case .boardFirmware: return "Collecting the firmware required by this board."
        case .firmwareArchive: return "Saving the original firmware and calibration so future updates can rebuild the same package."
        case .systemImage: return "Writing the selected image to its Linux partition and checking its archive CRC."
        case .systemFiles: return "Copying boot and system files. Keep your Mac plugged in and awake."
        case .extras: return "Fetching the additional files defined for this release. Stay connected to the internet."
        case .bootObject: return "Preserving the EFI partition identifiers and applying this board’s boot object alignment."
        case .installerData: return "Saving restore metadata and partition identities for repairs and firmware updates."
        case .reducedSecurity, .defaultBoot: return "Apple requires a macOS machine-owner login to select the new startup environment."
        case .restart: return "Shut down, wait 20 seconds, then hold the power button until startup options appear."
        case .check1TR: return "Finalization requires One True Recovery and the recovery environment paired with this installation."
        case .externalPreboot: return "Copying the matching administrator records for Apple’s external-volume boot registration."
        case .securityPolicy: return "This startup policy applies to Gravity Linux’s volume group. macOS keeps its own security policy."
        case .registerBoot: return "Registering m1n1 with Apple’s boot system using the existing entry point and address parameters."
        case .finish: return "Restoring the startup volume’s final markers. Don’t shut down until this finishes."
        case .complete: return "Restart to use Gravity Linux. Hold the power button at startup to choose macOS."
        case .repair: return "Refreshing startup authentication while preserving the Linux files and settings."
        case .uninstall: return "Removing only partitions recorded by this installation, then returning adjacent free space to macOS."
        }
    }
}
public struct InstallEvent: Codable, Sendable {
    public let step: InstallStep
    public let fraction: Double?
    public let detail: String?
    public let boardHelp: String?
    public let operationTitle: String?
    public init(_ step: InstallStep, fraction: Double? = nil, detail: String? = nil, help: String? = nil, title: String? = nil) {
        self.step = step; self.fraction = fraction; self.detail = detail; self.boardHelp = help; self.operationTitle = title
    }
    public var help: String { boardHelp ?? step.help }
    public var title: String { operationTitle ?? step.title }
}
public typealias EventSink = @Sendable (InstallEvent) -> Void

public enum InstallationMode: String, Codable, Sendable {
    case linux, uefi, bootloader
}
public struct Software: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let minimumBytes: Int64
    public let recommendedBytes: Int64
    public let developer: Bool
    public var mode: InstallationMode = .linux
}
public struct StorageTarget: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let maximumBytes: Int64
    public var unavailableReason: String? = nil
    public var existingFreeBytes: Int64? = nil
    public var unallocatedBytes: Int64 { kind == "free" ? alignDown(totalBytes) : existingFreeBytes ?? 0 }
    public var diagramTotalBytes: Int64 { totalBytes + (kind == "resize" ? unallocatedBytes : 0) }
    /// Existing free space is used first. macOS is only ever shrunk.
    public func shrinkBytes(for allocation: Int64) -> Int64 { kind == "resize" ? max(0, allocation - unallocatedBytes) : 0 }
    public func unusedBytes(for allocation: Int64) -> Int64 { max(0, unallocatedBytes - allocation) }
    public func resizedMacOSBytes(for allocation: Int64) -> Int64? {
        let change = shrinkBytes(for: allocation)
        return change == 0 ? nil : alignDown(totalBytes - change)
    }
    public func boundedAllocation(_ requestedBytes: Int64) -> Int64 { min(maximumBytes, max(0, alignDown(requestedBytes))) }
    public func canAllocate(_ allocation: Int64, minimumBytes: Int64) -> Bool { allocation >= alignDown(minimumBytes) && allocation <= maximumBytes }
}
public struct ExistingInstallation: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let needsFinalization: Bool
    public let canUninstall: Bool
}
public struct Inspection: Codable, Sendable {
    public let model: String
    public let bootMode: String
    public let administrator: String
    public let administrators: [String]
    public let targets: [StorageTarget]
    public var software: [Software]
    public let existing: [ExistingInstallation]
    public var board: BoardPresentation? = nil
    public var boardProfileID: String? = nil
    public var macOSReserveBytes: Int64 = BoardStoragePolicy.defaultMacOSReserveBytes
    public var minimumInstallBytes: Int64 = 30_000_000_000
}
public struct InstallSelection: Codable, Equatable, Sendable {
    public var targetID: String
    public var softwareID: String
    public var bytes: Int64
    public var name: String
    public init(targetID: String, softwareID: String, bytes: Int64, name: String = "Gravity Linux") {
        self.targetID = targetID; self.softwareID = softwareID; self.bytes = bytes; self.name = name
    }
}
public struct InstallPlan: Codable, Identifiable, Sendable {
    public let id: String
    public let selection: InstallSelection
    public let target: StorageTarget
    public let software: Software
    public let macOSAfterBytes: Int64?
    public let changes: [String]
    public var fingerprint: String? = nil
    public var policyFingerprint: String? = nil

    public func hasSameReview(as other: InstallPlan) -> Bool {
        selection == other.selection && target.id == other.target.id && target.kind == other.target.kind
            && target.name == other.target.name && target.totalBytes == other.target.totalBytes && target.unallocatedBytes == other.target.unallocatedBytes && software == other.software
            && macOSAfterBytes == other.macOSAfterBytes && changes == other.changes && fingerprint == other.fingerprint && policyFingerprint == other.policyFingerprint
    }
}
public struct Credentials: Sendable {
    public let username: String
    public let password: String
    public init(username: String, password: String) { self.username = username; self.password = password }
}
public struct EngineConfiguration: Sendable {
    public var resourceDirectory: URL
    public var catalogURL: URL
    public var repositoryURL: URL
    public var appBundle: URL?
    public var stage2URL: URL?
    public var developer = false
    public var developerOptions = DeveloperOptions()
    public var boardDeveloper: Bool { developer && developerOptions.allowUnsupportedMacs }
    public var bypassImageChecks: Bool { developer && developerOptions.bypassImageChecks }
    public var downloadCache: URL? {
        guard developer && developerOptions.keepDownloads else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("org.gravitylinux.installer/downloads", isDirectory: true)
    }
    var policyFingerprint: String { Data("\(boardDeveloper):\(bypassImageChecks)".utf8).sha256 }
    public var demo = false
    public init(resourceDirectory: URL, appBundle: URL? = nil, stage2URL: URL? = nil, demo: Bool = false,
                catalogURL: URL = ReleaseCatalog.productionURL, repositoryURL: URL = ReleaseCatalog.productionRepository) {
        self.resourceDirectory = resourceDirectory; self.appBundle = appBundle; self.stage2URL = stage2URL; self.demo = demo
        self.catalogURL = catalogURL; self.repositoryURL = repositoryURL
    }
}
public struct DeveloperOptions: Equatable, Sendable {
    public var customCDN = ""
    public var releaseChannel = "stable"
    public var bypassImageChecks = false
    public var allowUnsupportedMacs = false
    public var verboseLogging = true
    public var keepDownloads = false
    public init() {}
    public func sources(defaultCatalog: URL, defaultRepository: URL) throws -> (catalog: URL, repository: URL) {
        let text = customCDN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || releaseChannel != "stable" else { return (defaultCatalog, defaultRepository) }
        guard let base = text.isEmpty ? defaultRepository : URL(string: text), ["stable", "nightly"].contains(releaseChannel) else { throw InstallerError("Enter a valid CDN URL and release channel.") }
        try ReleaseCatalog.validateSource(base)
        return (base.appendingPathComponent(releaseChannel == "nightly" ? "installer-dev/installer_data.json" : "installer/installer_data.json"), base)
    }
}
public enum GuideLinks {
    // Publishing these two pages is the only documentation hosting requirement.
    public static let recovery = URL(string: "https://gravitylinux.org/finish")!
    public static let safety = URL(string: "https://gravitylinux.org/docs/installer-safety")!
}
public struct PartitionTemplate: Codable, Sendable {
    let name: String, type: String, size: String
    let format: String?, image: String?, source: String?
    let expand: Bool?, copy_firmware: Bool?, copy_installer_data: Bool?, volume_id: String?
    public init(name: String, type: String, size: String, format: String? = nil, image: String? = nil, source: String? = nil,
                expand: Bool = false, copyFirmware: Bool = false, copyInstallerData: Bool = false, volumeID: String? = nil) {
        self.name = name; self.type = type; self.size = size; self.format = format; self.image = image; self.source = source
        self.expand = expand; copy_firmware = copyFirmware; copy_installer_data = copyInstallerData; volume_id = volumeID
    }
    var bytes: Int64 { get throws { alignUp(try parseSize(size)) } }
}
public struct SoftwareTemplate: Codable, Sendable {
    let name: String, default_os_name: String, boot_object: String
    let package: String?, icon: String?, next_object: String?
    let expert: Bool
    let extras: [String]?
    let partitions: [PartitionTemplate]
    let mode: InstallationMode
    let supported_boards: [String]?, supported_devices: [String]?, supported_fw: [String]?
    public init(name: String, mode: InstallationMode, bootObject: String = "m1n1.bin", package: URL? = nil,
                partitions: [PartitionTemplate] = [], defaultOSName: String = "Gravity Linux", icon: String? = nil,
                nextObject: String? = nil, developer: Bool = false, extras: [URL] = []) {
        self.name = name; self.mode = mode; boot_object = bootObject; self.package = package?.absoluteString
        self.partitions = partitions; default_os_name = defaultOSName; self.icon = icon; next_object = nextObject
        expert = developer; self.extras = extras.map(\.absoluteString)
        supported_boards = nil; supported_devices = nil; supported_fw = nil
    }
    enum CodingKeys: String, CodingKey {
        case name, default_os_name, boot_object, package, icon, next_object, expert, extras, partitions
        case mode = "install_mode"
        case supported_boards, supported_devices, supported_fw
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        default_os_name = try values.decodeIfPresent(String.self, forKey: .default_os_name) ?? "Gravity Linux"
        boot_object = try values.decodeIfPresent(String.self, forKey: .boot_object) ?? "m1n1.bin"
        package = try values.decodeIfPresent(String.self, forKey: .package)
        icon = try values.decodeIfPresent(String.self, forKey: .icon)
        next_object = try values.decodeIfPresent(String.self, forKey: .next_object)
        expert = try values.decodeIfPresent(Bool.self, forKey: .expert) ?? false
        extras = try values.decodeIfPresent([String].self, forKey: .extras)
        partitions = try values.decodeIfPresent([PartitionTemplate].self, forKey: .partitions) ?? []
        mode = try values.decodeIfPresent(InstallationMode.self, forKey: .mode) ?? .linux
        supported_boards = try values.decodeIfPresent([String].self, forKey: .supported_boards)
        supported_devices = try values.decodeIfPresent([String].self, forKey: .supported_devices)
        supported_fw = try values.decodeIfPresent([String].self, forKey: .supported_fw)
    }
    func supports(_ board: BoardProfile) -> Bool {
        if let ids = supported_boards, !ids.contains(board.id) { return false }
        if let devices = supported_devices, !devices.contains(board.deviceClass) { return false }
        if supported_boards == nil && supported_devices == nil && !board.acceptsUnscopedImages { return false }
        if let versions = supported_fw, !versions.contains(board.restore.version) { return false }
        return board.installationModes.contains(mode)
    }
    public static let bootloaderOnly = SoftwareTemplate(name: "Bootloader only", mode: .bootloader, developer: true)
    static func bootloaderOnly(bootObject: String) -> SoftwareTemplate {
        SoftwareTemplate(name: bootloaderOnly.name, mode: .bootloader, bootObject: bootObject, developer: true)
    }
    var layout: [PartitionTemplate] {
        switch mode {
        case .linux: return partitions
        case .uefi: return partitions.filter { $0.type.uppercased() == "EFI" }
        case .bootloader: return []
        }
    }
    var minimum: Int64 { get throws { try layout.reduce(0) { try $0 + $1.bytes } } }
    var expandable: Bool { mode == .linux && layout.contains { $0.expand == true } }
    func software(id: String, storage: BoardStoragePolicy = BoardStoragePolicy()) throws -> Software {
        let minimum = try self.minimum
        let recommended = max(storage.minimumLinuxBytes, storage.stubBytes + (expandable ? minimum * 2 : minimum))
        return Software(id: id, name: name, minimumBytes: mode == .linux ? recommended : storage.stubBytes + minimum, recommendedBytes: recommended, developer: expert == true, mode: mode)
    }
}
