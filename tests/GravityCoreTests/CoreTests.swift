// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

func der(_ tag: UInt8, _ body: Data) -> Data {
    var result = Data([tag])
    if body.count < 128 { result.append(UInt8(body.count)) }
    else {
        var bytes = Data(); var n = body.count
        repeat { bytes.insert(UInt8(n & 255), at: 0); n >>= 8 } while n > 0
        result.append(UInt8(0x80 | bytes.count)); result.append(bytes)
    }
    result.append(body); return result
}
func seq(_ items: [Data]) -> Data { der(0x30, items.reduce(Data(), +)) }
func integer(_ n: UInt64) -> Data {
    var bytes = Data(); var n = n
    repeat { bytes.insert(UInt8(n & 255), at: 0); n >>= 8 } while n > 0
    if bytes[0] & 128 != 0 { bytes.insert(0, at: 0) }; return der(2, bytes)
}
func ascii(_ text: String) -> Data { der(0x16, Data(text.utf8)) }
func factory(_ blobs: [Data], record: String = "BTBF") throws -> Data {
    let records = seq([integer(try Data("BWCl".utf8).uint(0, 4))] + blobs.map { seq([integer(try! Data(record.utf8).uint(0, 4)), ascii("synthetic"), der(4, $0)]) })
    return seq([ascii("IMG4"), seq([ascii("IM4P"), ascii("BWCl"), ascii("synthetic"), der(4, records)])])
}

@Test func calibrationRecordsAndAddressValidation() throws {
    let blob = Data("BLOB".utf8) + Data((0...255).map(UInt8.init))
    #expect(try RadioCalibration.extract(factory([blob]), record: "BTBF") == blob)
    #expect(try RadioCalibration.extract(factory([blob], record: "WCAL"), record: "WCAL") == blob)
    for raw in [try factory([]), try factory([blob, blob]), try factory([Data("bad!".utf8)]), try factory([Data("BLOB".utf8) + Data(count: 32768)]), Data(try factory([blob]).dropLast()), try factory([blob]) + Data([0]), Data(count: 1_048_577)] {
        #expect(throws: (any Error).self) { try RadioCalibration.extract(raw, record: "BTBF") }
    }
    for address in ["000000000000", "ffffffffffff", "011122334455", "../bad", "02112233445G"] {
        #expect(throws: (any Error).self) { try RadioCalibration.validateAddress(address) }
    }
    let tree: [[String: Any]] = [["IORegistryEntryName": "chosen", "mac-address-bluetooth0": Data([2,17,34,51,68,85])]]
    #expect(try RadioCalibration.address(in: tree, property: "mac-address-bluetooth0") == "021122334455")
    #expect(throws: (any Error).self) { try RadioCalibration.address(in: tree + tree, property: "mac-address-bluetooth0") }
}
@Test func calibrationCollectionConflictsAndRoundTrip() throws {
    let temp = try TemporaryDirectory(), blob = Data("BLOB-test".utf8)
    let tree: [[String: Any]] = [["IORegistryEntryName": "chosen", "mac-address-wifi0": Data([2,17,34,51,68,85])]]
    #expect(try RadioCalibration.collect(.wifi, factory: temp.url, tree: tree) == nil)
    for name in ["one", "two"] { try factory([blob], record: "WCAL").write(to: temp.url.appending("BWCl-sakhalin-4388-C2-" + name)) }
    let calibration = try #require(try RadioCalibration.collect(.wifi, factory: temp.url, tree: tree))
    #expect(calibration.provenance.count == 2); try calibration.writeRaw(to: temp.url)
    let restored = try #require(try RadioCalibration.fromArchive(.wifi, root: temp.url))
    #expect(restored.data == blob && restored.address == "021122334455")
    try write(Data("BLOB-tampered".utf8), to: temp.url.appending("apple/wifi-calibration.bin"))
    #expect(throws: (any Error).self) { try RadioCalibration.fromArchive(.wifi, root: temp.url) }
    try factory([Data("BLOB-conflict".utf8)], record: "WCAL").write(to: temp.url.appending("BWCl-sakhalin-4388-C2-two"))
    #expect(throws: (any Error).self) { try RadioCalibration.collect(.wifi, factory: temp.url, tree: tree) }
}
@Test func m4FirmwareProfileAndArchives() throws {
    let temp = try TemporaryDirectory(), wifi = temp.url.appending("wifi"), bluetooth = temp.url.appending("bluetooth")
    for (dest, source) in J773gFirmwareCollectors.wifiAliases { try write(Data((dest.hasSuffix(".txt") ? "boardrev =0x14\nmacaddr=00:00:00:00:00:00\n" : dest).utf8), to: wifi.appending(source)) }
    try mkdir(bluetooth)
    for (vendor, content) in [("AMKOR", "correct"), ("USI", "wrong")] {
        for ext in ["bin", "ptb"] { try write(Data((content + ext).utf8), to: bluetooth.appending("BCM4388C2_23.5_PCIE_macOS_Willamette_Sakhalin_CLPC_3ANT_OS_\(vendor)_20251203.\(ext)")) }
    }
    let wifiFiles = try J773gFirmwareCollectors.wifi(wifi), btFiles = try J773gFirmwareCollectors.bluetooth(bluetooth)
    #expect(Set(wifiFiles.map(\.name)) == Set(J773gFirmwareCollectors.wifiAliases.keys))
    #expect(btFiles.count == 2 && btFiles.allSatisfy { String(decoding: $0.data, as: UTF8.self).hasPrefix("correct") })
    #expect(String(decoding: try #require(wifiFiles.first { $0.name.hasSuffix(".txt") }).data, as: UTF8.self).hasPrefix("boardrev=0x14\n"))
    let output = temp.url.appending("output"), package = try FirmwarePackage(output)
    try package.add(wifiFiles + btFiles)
    try package.add(FirmwareFile(name: "duplicate.bin", data: btFiles[0].data))
    let calibration = FirmwareFile(name: "brcm/brcmbt4388-021122334455-bf.bin", data: Data("BLOB-test".utf8), includeInBootloader: true); try package.add(calibration)
    try package.close()
    #expect(try Data(contentsOf: output.appending("u-boot/" + calibration.name)) == calibration.data)
    let manifest = try String(contentsOf: output.appending("manifest.txt"))
    #expect(manifest.contains("LINK duplicate.bin \(btFiles[0].name)"))
    let tarList = String(decoding: try SystemCommands().run("/usr/bin/tar", ["-tf", output.appending("firmware.tar").path], input: nil), as: UTF8.self)
    #expect(tarList.contains("duplicate.bin") && !tarList.contains(".vendorfw.manifest"))
    let extracted = temp.url.appending("extracted"); try mkdir(extracted)
    _ = try SystemCommands().run("/usr/bin/tar", ["-xf", output.appending("firmware.cpio").path, "-C", extracted.path], input: nil)
    #expect(try Data(contentsOf: extracted.appending("vendorfw/duplicate.bin")) == btFiles[0].data)
    #expect(try String(contentsOf: extracted.appending("vendorfw/.vendorfw.manifest")) == manifest)
    try fm.removeItem(at: wifi.appending("C-4388__s-C2/sakhalin.sig"))
    #expect(throws: (any Error).self) { try J773gFirmwareCollectors.wifi(wifi) }
    for url in try fm.contentsOfDirectory(at: bluetooth, includingPropertiesForKeys: nil) where url.lastPathComponent.contains("AMKOR") && url.pathExtension == "ptb" { try fm.removeItem(at: url) }
    #expect(throws: (any Error).self) { try J773gFirmwareCollectors.bluetooth(bluetooth) }
}
@Test func im4pASMediaAndBootObject() throws {
    var kernel = Data(count: 19); kernel.append(Data("2214A_RCFG".utf8)); kernel.append(Data(count: 0x2f - Data("2214A_RCFG".utf8).count)); kernel.appendLE(0x18000); kernel.append(Data(repeating: 0x42, count: 0x18000))
    let temp = try TemporaryDirectory(), path = temp.url.appending("kernelcache")
    try seq([ascii("IM4P"), ascii("krnl"), ascii("synthetic"), der(4, kernel)]).write(to: path)
    let files = try J773gFirmwareCollectors.kernel(path)
    #expect(files.count == 1 && files[0].data == Data(repeating: 0x42, count: 0x18000))
    let raw = Data("m1n1-STACKBOT".utf8), variables = ["chosen.gravity,efi-system-partition=fixture", "chainload=fixture;m1n1/boot.bin"]
    let boot = try BootObject.build(raw, variables: variables)
    #expect(boot.count % 65536 == 0 && boot.starts(with: raw))
    #expect(try BootObject.variables(boot) == variables)
    #expect(throws: (any Error).self) { try BootObject.build(raw, variables: ["injected\nvariable"]) }
}

/// Small ZIP builder lets corrupt central directories and CRCs be tested without Apple bytes.
func storedZIP(name: String, data: Data, zip64: Bool = false, badCRC: Bool = false) -> Data {
    var result = Data(), central = Data(); let filename = Data(name.utf8)
    let crc: UInt64 = badCRC ? 0 : UInt64(data.crc32)
    result.appendLE(0x04034b50); result.appendLE(20, bytes: 2); result.appendLE(0, bytes: 2); result.appendLE(0, bytes: 2); result.appendLE(0); result.appendLE(crc); result.appendLE(UInt64(data.count)); result.appendLE(UInt64(data.count)); result.appendLE(UInt64(filename.count), bytes: 2); result.appendLE(0, bytes: 2); result.append(filename); result.append(data)
    central.appendLE(0x02014b50); central.appendLE(20, bytes: 2); central.appendLE(20, bytes: 2); central.appendLE(0, bytes: 2); central.appendLE(0, bytes: 2); central.appendLE(0); central.appendLE(crc); central.appendLE(UInt64(data.count)); central.appendLE(UInt64(data.count)); central.appendLE(UInt64(filename.count), bytes: 2); central.appendLE(0, bytes: 2); central.appendLE(0, bytes: 2); central.appendLE(0, bytes: 2); central.appendLE(0, bytes: 2); central.appendLE(0); central.appendLE(0); central.append(filename)
    let offset = result.count; result.append(central)
    if zip64 {
        let record = result.count
        result.appendLE(0x06064b50); result.appendLE(44, bytes: 8); result.appendLE(45, bytes: 2); result.appendLE(45, bytes: 2); result.appendLE(0); result.appendLE(0)
        result.appendLE(1, bytes: 8); result.appendLE(1, bytes: 8); result.appendLE(UInt64(central.count), bytes: 8); result.appendLE(UInt64(offset), bytes: 8)
        result.appendLE(0x07064b50); result.appendLE(0); result.appendLE(UInt64(record), bytes: 8); result.appendLE(1)
    }
    result.appendLE(0x06054b50); result.appendLE(0, bytes: 2); result.appendLE(0, bytes: 2); result.appendLE(zip64 ? 65535 : 1, bytes: 2); result.appendLE(zip64 ? 65535 : 1, bytes: 2); result.appendLE(zip64 ? 0xffffffff : UInt64(central.count)); result.appendLE(zip64 ? 0xffffffff : UInt64(offset)); result.appendLE(0, bytes: 2)
    return result
}
@Test func zipAndZIP64IntegrityAndPathTraversal() throws {
    let temp = try TemporaryDirectory(), file = temp.url.appending("test.zip"), payload = Data("fixture-data".utf8)
    for zip64 in [false, true] {
        try storedZIP(name: "folder/file", data: payload, zip64: zip64).write(to: file)
        #expect(try ZIPArchive(file).data("folder/file") == payload)
    }
    try storedZIP(name: "file", data: payload, badCRC: true).write(to: file)
    #expect(throws: (any Error).self) { try ZIPArchive(file).data("file") }
    try storedZIP(name: "root/../escape", data: payload).write(to: file)
    #expect(throws: (any Error).self) { try ZIPArchive(file).extractTree("root", to: temp.url.appending("output")) }
    try Data([0, 1, 2]).write(to: file)
    #expect(throws: (any Error).self) { try ZIPArchive(file) }
}
@Test func deflateZIPStreaming() throws {
    let temp = try TemporaryDirectory(), input = temp.url.appending("input"), archive = temp.url.appending("archive.zip")
    let bytes = Data(repeating: 0x42, count: 3_000_000); try bytes.write(to: input)
    _ = try SystemCommands().run("/usr/bin/zip", ["-jq", archive.path, input.path], input: nil)
    #expect(try ZIPArchive(archive).data("input") == bytes)
}
final class CommandSpy: CommandRunning, @unchecked Sendable {
    var calls: [(String, [String])] = []
    var policy: String
    init(policy: String) { self.policy = policy }
    func run(_ executable: String, _ arguments: [String], input: Data?) throws -> Data {
        calls.append((executable, arguments))
        if executable.hasSuffix("bputil") && arguments.first == "-d" { return Data(policy.utf8) }
        return Data()
    }
}
func stage2Fixture(_ temp: TemporaryDirectory) throws -> URL {
    let resources = temp.url.appending("Gravity Linux/Finish Installation.app/Contents/Resources"), config = resources.appending("stage2.json")
    let record = Stage2Record(version: 1, vgid: "00000000-1111-2222-3333-444444444444", prebootUUID: "00000000-1111-2222-3333-555555555555", name: "Gravity Linux", macOSPartitionUUID: "fixture-macOS", partitions: [], ready: true, complete: false)
    try write(JSONEncoder().encode(record), to: config); try write(Data("boot-object".utf8), to: resources.appending("boot.bin")); return config
}
@Test func stage2RejectsWrongRecoveryBeforeMutation() throws {
    let temp = try TemporaryDirectory(), context = try Stage2Context(stage2Fixture(temp))
    for policy in ["Current OS environment: macOS\nPairing: Paired\n", "Current OS environment: one true recoveryOS\nPairing: Unpaired\n"] {
        let commands = CommandSpy(policy: policy)
        #expect(throws: (any Error).self) { try context.finalize(commands: commands, credentials: Credentials(username: "fixture", password: "secret"), events: { _ in }) }
        #expect(commands.calls.count == 1 && commands.calls[0].1.first == "-d")
    }
}
@Test func stage2PreservesRegistrationParametersAndFinishes() throws {
    let temp = try TemporaryDirectory(), context = try Stage2Context(stage2Fixture(temp))
    let disabled = context.system.appending("System/Library/CoreServices/SystemVersion-disabled.plist")
    try write(Data("system-version".utf8), to: disabled); try write(Data("media".utf8), to: context.system.appending(".IAPhysicalMedia"))
    let commands = CommandSpy(policy: "Current OS environment: one true recoveryOS\nPairing: Paired\n")
    try context.finalize(commands: commands, credentials: Credentials(username: "fixture", password: "secret"), events: { _ in })
    let bputil = try #require(commands.calls.first { $0.1.first == "-nc" })
    #expect(bputil.1 == ["-nc", "-v", context.record.vgid] && !bputil.1.contains("secret"))
    let kmutil = try #require(commands.calls.first { $0.0.hasSuffix("kmutil") })
    #expect(kmutil.1 == ["configure-boot", "-c", context.resources.appending("boot.bin").path, "--raw", "--entry-point", "2048", "--lowest-virtual-address", "0", "-v", context.system.path])
    #expect(try JSONDecoder().decode(Stage2Record.self, from: Data(contentsOf: context.configURL)).complete)
    #expect(fm.fileExists(atPath: context.system.appending("System/Library/CoreServices/SystemVersion.plist").path))
    #expect(!fm.fileExists(atPath: context.system.appending(".IAPhysicalMedia").path))
}
@Test func realPTYAnswersConfirmationAndWaitsForEchoOff() throws {
    let temp = try TemporaryDirectory(), script = temp.url.appending("auth.sh")
    let text = """
    #!/bin/sh
    printf 'Enter username: '
    read -r username
    [ "$username" = 'fixture-user' ] || exit 11
    printf 'Continue? (y/N): '
    read -r confirmation
    [ "$confirmation" = y ] || exit 12
    printf 'Password: '
    sleep 0.2
    stty -echo
    read -r password
    stty echo
    [ "$password" = 'fixture-password' ] || exit 13
    printf '\\nFinished\\n'
    """
    try write(Data(text.utf8), to: script); try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    try SystemCommands().authenticated(script.path, [], credentials: Credentials(username: "fixture-user", password: "fixture-password"))
}
@Test func demoPlansValidateBoundsAndCannotBeReused() async throws {
    var config = EngineConfiguration(resourceDirectory: URL(fileURLWithPath: "/does-not-exist")); config.demo = true
    let engine = InstallerEngine(configuration: config), inspection = try await engine.inspect()
    let target = try #require(inspection.targets.first), software = try #require(inspection.software.first)
    let plan = try await engine.plan(InstallSelection(targetID: target.id, softwareID: software.id, bytes: 120_000_000_000))
    #expect(plan.macOSAfterBytes! >= target.totalBytes - target.maximumBytes)
    try await engine.install(planID: plan.id, credentials: Credentials(username: "demo", password: "demo"))
    do { try await engine.install(planID: plan.id, credentials: Credentials(username: "demo", password: "demo")); Issue.record("Plan reused") } catch {}
    do { _ = try await engine.plan(InstallSelection(targetID: target.id, softwareID: software.id, bytes: 500_000_000_000)); Issue.record("Oversized plan accepted") } catch {}
}
@Test func recoveryPinsAndProgressCatalog() throws {
    let profile = J773g.restore
    #expect(profile.member == "022-22048-093.dmg.aea")
    guard case let .aea(encryptedSHA256, _) = profile.encoding else { Issue.record("M4 must retain AEA recovery"); return }
    #expect(encryptedSHA256 == "4e91f4949f0614de01f44434bce2a5a45b0e0a92ca0e3b06cd55c229752a9754")
    #expect(profile.decodedSHA256 == "eeda386b1fb66a313cadef26e3e7ee06643d4d5ea8b3330a411a118ac7d14ed3")
    #expect(InstallStep.allCases.count >= 40)
    #expect(Set(InstallStep.allCases.map(\.help)).count >= 30)
    #expect(InstallStep.allCases.allSatisfy { !$0.help.isEmpty && !$0.title.isEmpty })
}

@Test func partitionModesKeepFutureOSSpaceFree() throws {
    let partitionList = """
    [{"name":"EFI","type":"EFI","size":"500MB","expand":true},
     {"name":"Linux","type":"Linux","size":"5GB","expand":true}]
    """
    func template(_ mode: String) throws -> SoftwareTemplate {
        let data = Data("{\"name\":\"Fixture\",\"default_os_name\":\"Gravity Linux\",\"boot_object\":\"m1n1.bin\",\"install_mode\":\"\(mode)\",\"partitions\":\(partitionList)}".utf8)
        return try JSONDecoder().decode(SoftwareTemplate.self, from: data)
    }
    let uefi = try template("uefi"), bootloader = try template("bootloader"), linux = try template("linux")
    #expect(uefi.layout.count == 1 && uefi.layout[0].type == "EFI" && !uefi.expandable)
    #expect(try uefi.minimum == alignUp(500_000_000))
    #expect(bootloader.layout.isEmpty && !bootloader.expandable)
    #expect(try bootloader.minimum == 0)
    #expect(linux.layout.count == 2 && linux.expandable)
}

final class PartitionCommands: CommandRunning, @unchecked Sendable {
    var added: [[String: Any]]
    var mutated = false
    let existing: [[String: Any]] = [
        ["name":"disk0s4", "type":"EFI", "uuid":"existing-efi"],
        ["name":"disk0s7", "type":"Linux Filesystem", "uuid":"existing-linux"]
    ]
    init(added: [[String: Any]]) { self.added = added }
    func run(_ executable: String, _ arguments: [String], input: Data?) throws -> Data {
        if arguments.first == "addPartition" { mutated = true; return Data() }
        let parts = existing + (mutated ? added : [])
        let object: [String: Any]
        if arguments.first == "list" {
            object = ["WholeDisks": ["disk0"], "AllDisksAndPartitions": [["DeviceIdentifier":"disk0", "Size":10_000_000_000, "Partitions":parts.map { ["DeviceIdentifier": $0["name"]!] }]]]
        } else if arguments.prefix(2) == ["apfs", "list"] { object = ["Containers": []] }
        else if arguments.first == "info" {
            if arguments.last == "disk0" { object = ["Internal":true, "VirtualOrPhysical":"Physical"] }
            else {
                let part = try #require(parts.first { string($0["name"]) == arguments.last })
                object = ["DeviceIdentifier":part["name"]!, "Content":part["type"]!, "DiskUUID":part["uuid"]!, "PartitionMapPartitionOffset":1_000_000_000, "Size":1_073_741_824]
            }
        } else { throw InstallerError("Unexpected fixture command") }
        return try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }
}
@Test func partitionSelectionUsesNewUUIDAndCanonicalLinuxType() throws {
    let wanted: [String: Any] = ["name":"disk0s6", "type":"Linux Filesystem", "uuid":"new-linux"]
    let helper: [String: Any] = ["name":"disk0s5", "type":"Apple_Boot", "uuid":"helper"]
    let commands = PartitionCommands(added: [helper, wanted]), disk = DiskManager(commands: commands)
    try disk.refresh()
    #expect(try disk.addPartition(after: "disk0s4", type: "%Linux%", label: "%noformat%", size: 1_073_741_824, disk: "disk0").uuid == "new-linux")
    for added in [[], [helper], [wanted, ["name":"disk0s8", "type":"Linux Filesystem", "uuid":"second-new"]]] {
        let disk = DiskManager(commands: PartitionCommands(added: added)); try disk.refresh()
        #expect(throws: (any Error).self) { try disk.addPartition(after: "disk0s4", type: "%Linux%", label: "%noformat%", size: 1_073_741_824, disk: "disk0") }
    }
}

@Test func realPTYReportsRejectedPassword() throws {
    let temp = try TemporaryDirectory(), script = temp.url.appending("reject.sh")
    try write(Data("#!/bin/sh\nstty -echo\nprintf 'Password: '\nread -r password\nstty echo\nexit 17\n".utf8), to: script)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    #expect(throws: (any Error).self) { try SystemCommands().authenticated(script.path, [], credentials: Credentials(username: "fixture-user", password: "wrong-password")) }
}
@Test func uefiPlanReservesFutureSpaceWithoutGrowingESP() async throws {
    let engine = InstallerEngine(configuration: EngineConfiguration(resourceDirectory: URL(fileURLWithPath: "/no-assets"), demo: true))
    let info = try await engine.inspect(), target = try #require(info.targets.first), uefi = try #require(info.software.first { $0.mode == .uefi })
    let plan = try await engine.plan(InstallSelection(targetID: target.id, softwareID: uefi.id, bytes: 120_000_000_000))
    #expect(plan.selection.bytes > 119_000_000_000)
    #expect(plan.changes.contains { $0.contains("unallocated for a future operating system") })
    #expect(plan.changes.contains { $0.contains("only the startup stub and EFI") })
}

@Test func nativeAPFSCompressionReadback() throws {
    let temp = try TemporaryDirectory(), source = temp.url.appending("source.dmg"), destination = temp.url.appending("compressed.dmg")
    var input = Data(repeating: 0x42, count: 65536 * 3 + 17)
    input.replaceSubrange(65000..<66000, with: Data((0..<1000).map { UInt8(truncatingIfNeeded: $0) }))
    try input.write(to: source)
    do { try APFSCompression.compress(source: source, destination: destination, crc: input.crc32, events: { _ in }) }
    catch {
        let attributes = try? SystemCommands().run("/usr/bin/xattr", ["-l", destination.path], input: nil)
        print("Compression fixture attributes: \(String(decoding: attributes ?? Data(), as: UTF8.self))")
        throw error
    }
    #expect(try Data(contentsOf: destination) == input)
    #expect(try checksums(destination).sha256 == input.sha256)
}
