// SPDX-License-Identifier: GPL-2.0-only
import Foundation

public enum InstallStep: String, Codable, CaseIterable, Sendable {
    case inspecting, metadata, package, ipsw, validateRecovery, decodeRecovery, verifyRecovery
    case resize, createStub, volumes, systemVolume, dataVolume, preboot, bootability, restoreFirmware, administrators
    case recoveryVolume, compressRecovery, stage2App, partition, format, calibration, wifi, bluetooth, multitouch, kernel, boardFirmware, firmwareArchive
    case systemImage, systemFiles, extras, bootObject, installerData, reducedSecurity, defaultBoot, restart
    case check1TR, externalPreboot, securityPolicy, registerBoot, finish, complete, repair, uninstall
    public var title: String {
        switch self {
        case .inspecting: return "Checking this Mac"
        case .metadata: return "Loading available software"
        case .package: return "Opening the Gravity Linux package"
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
        case .metadata: return "The release catalog determines which desktops and images are available for this Mac."
        case .package: return "Only the needed parts of the software archive are downloaded."
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
        case .extras: return "Fetching the additional files listed in the release catalog. Stay connected to the internet."
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
public struct Software: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let minimumBytes: Int64
    public let recommendedBytes: Int64
    public let developer: Bool
    public var mode: InstallationMode = .linux
}
public struct StorageTarget: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let maximumBytes: Int64
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
    public let software: [Software]
    public let existing: [ExistingInstallation]
    public var board: BoardPresentation? = nil
    public var boardProfileID: String? = nil
    public var macOSReserveBytes: Int64 = 40_000_000_000
}
public struct InstallSelection: Codable, Sendable {
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
}
public struct Credentials: Sendable {
    public let username: String
    public let password: String
    public init(username: String, password: String) { self.username = username; self.password = password }
}
public struct EngineConfiguration: Sendable {
    public var resourceDirectory: URL
    public var catalogURL: URL?
    public var repositoryURL: URL?
    public var appBundle: URL?
    public var stage2URL: URL?
    public var developer = false
    public var demo = false
    public init(resourceDirectory: URL, catalogURL: URL? = nil, repositoryURL: URL? = nil, appBundle: URL? = nil, stage2URL: URL? = nil, demo: Bool = false) {
        self.resourceDirectory = resourceDirectory; self.catalogURL = catalogURL; self.repositoryURL = repositoryURL; self.appBundle = appBundle; self.stage2URL = stage2URL; self.demo = demo
    }
}
public enum GuideLinks {
    // Publishing these two pages is the only documentation hosting requirement.
    public static let recovery = URL(string: "https://gravitylinux.org/finish")!
    public static let safety = URL(string: "https://gravitylinux.org/docs/installer-safety")!
}
struct PartitionTemplate: Decodable, Sendable {
    let name: String, type: String, size: String
    let format: String?, image: String?, source: String?
    let expand: Bool?, copy_firmware: Bool?, copy_installer_data: Bool?, volume_id: String?
    var bytes: Int64 { get throws { alignUp(try parseSize(size)) } }
}
struct SoftwareTemplate: Decodable, Sendable {
    let name: String, default_os_name: String, boot_object: String
    let package: String?, icon: String?, next_object: String?
    let expert: Bool?, external_boot: Bool?, supported_fw: [String]?, extras: [String]?
    let partitions: [PartitionTemplate]
    let install_mode: InstallationMode?
    let supported_boards: [String]?
    let supported_devices: [String]?
    func supports(_ board: BoardProfile) -> Bool {
        if let ids = supported_boards, !ids.contains(board.id) { return false }
        if let devices = supported_devices, !devices.contains(board.deviceClass) { return false }
        if supported_boards == nil && supported_devices == nil && !board.allowsLegacyCatalog { return false }
        if let versions = supported_fw, !versions.contains(board.restore.version) { return false }
        return board.installationModes.contains(mode)
    }
    var mode: InstallationMode {
        if let install_mode { return install_mode }
        // Compatibility with existing release catalogs. New catalogs should
        // specify install_mode explicitly; the layout policy is always enforced.
        let title = name.lowercased()
        if title.contains("uefi") { return .uefi }
        if title.contains("tethered") || title.contains("bootloader only") { return .bootloader }
        return .linux
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
struct Catalog: Decodable { let os_list: [SoftwareTemplate] }
