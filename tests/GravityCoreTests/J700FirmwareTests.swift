// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

@Test func j700BoardHasItsOwnIdentityAndKeepsLegacyMapping() throws {
    let registry = BoardRegistry.builtIn
    #expect(try registry.resolve(HardwareIdentity(deviceClass: "J700AP", chipID: 0x8140, boardID: 0x64), developer: true).id == "j700")
    #expect(throws: (any Error).self) { try registry.resolve(HardwareIdentity(deviceClass: "j700ap", chipID: 0x8140, boardID: 1)) }
    #expect(try registry.savedProfile(id: nil).id == "j773g")
    #expect(J700.profile.restore.member == J773g.restore.member)
    #expect(J700.profile.restore.decodedSHA256 == J773g.restore.decodedSHA256)
    #expect(J700.profile.installationModes.contains(.linux))
}

private func j700Setfile(_ fill: UInt8) -> Data {
    var result = Data(count: J700FirmwareCollectors.cameraSize)
    for (i, n) in [0x19250306, 0x04050000, 0, 0, 0x21000000, 0x641e0000, 0, 0x03c00000].enumerated() {
        for j in 0..<4 { result[i * 4 + j] = UInt8(truncatingIfNeeded: n >> ((3-j)*8)) }
    }
    result[100] = fill
    return result
}
@Test func j700CameraAcceptsIdenticalFatSlicesAndRejectsConflicts() throws {
    let setfile = j700Setfile(1)
    var input = setfile
    while input.count % 4096 != 0 { input.append(0) }
    input.append(setfile)
    #expect(try J700FirmwareCollectors.camera(input).data == setfile)
    var conflict = input; conflict[conflict.count - setfile.count + 100] = 2
    #expect(throws: (any Error).self) { try J700FirmwareCollectors.camera(conflict) }
    #expect(throws: (any Error).self) { try J700FirmwareCollectors.camera(Data(count: 4096)) }
    var invalid = setfile; invalid[8] = 1
    #expect(throws: (any Error).self) { try J700FirmwareCollectors.camera(invalid) }
}

@Test func j700RejectsWrongBluetoothRelease() throws {
    #expect(throws: (any Error).self) { try J700FirmwareCollectors.bluetooth(Data(count: 611680)) }
}

@Test func j700CalibrationRequiresFactoryBindingAndRejectsTruncation() throws {
    let temp = try TemporaryDirectory(), address = "021122334455", mac = Data([2,17,34,51,68,85])
    let rf = Data(repeating: 0x7e, count: 16)
    var startup = Data("MT7932C1".utf8) + mac + Data([0,0]); startup.appendLE(1)
    startup.append(contentsOf: [0xed,0x21,1,0]); startup.appendLE(20)
    startup.append(contentsOf: [3,0,16,0]); startup.append(rf)
    var precal = Data("MT7932P1".utf8) + mac; precal.appendLE(1, bytes: 2); precal.appendLE(56)
    precal.append(contentsOf: [3,0,0,0]); precal.appendLE(16); precal.append(Data(count: 12)); precal.append(rf)
    let one = temp.url.appending("mediatek/mt7932/calibration-\(address).bin"), two = temp.url.appending("mediatek/mt7932/precal-\(address).bin")
    try write(startup, to: one); try write(precal, to: two)
    func files() throws -> [FirmwareFile] { [FirmwareFile(name: "mediatek/mt7932/" + one.lastPathComponent, data: try Data(contentsOf: one)), FirmwareFile(name: "mediatek/mt7932/" + two.lastPathComponent, data: try Data(contentsOf: two))] }
    #expect(try J700FirmwareCollectors.validateCalibration(files(), address: address, factory: rf).count == 2)
    #expect(throws: (any Error).self) { try J700FirmwareCollectors.validateCalibration(files(), address: "021122334456", factory: rf) }
    #expect(throws: (any Error).self) { try J700FirmwareCollectors.validateCalibration(files(), address: address, factory: Data(repeating: 0, count: 32)) }
    try write(Data(precal.dropLast()), to: two)
    #expect(throws: (any Error).self) { try J700FirmwareCollectors.validateCalibration(files(), address: address, factory: rf) }
}

private func factoryOCATable() -> Data {
    let sizes = [(0x1001, 328), (0x1002, 20), (0x1003, 20), (0x1011, 336), (0x1012, 320), (0x1021, 336), (0x1022, 600),
        (0x2000, 1584), (0x2080, 712), (0x2008, 2160), (0x2010, 2160), (0x201c, 2160),
        (0x4006, 20), (0x3086, 2448), (0x3006, 4896), (0x420f, 20), (0x320f, 1224)]
    func be(_ value: Int, _ count: Int) -> Data { Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    var table = Data("BLOB".utf8) + be(16 + sizes.count * 20, 4) + be(12, 2) + be(sizes.count, 2) + Data(count: 4)
    var bodies = Data()
    for (id, size) in sizes {
        let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 + id) })
        let body = be(id, 2) + be(12, 2) + be(8 + size, 4) + payload
        table.append(be(id, 2) + be(12, 2) + be(16 + sizes.count * 20 + bodies.count, 4) + be(body.count, 4) + be(body.reduce(0) { $0 + Int($1) }, 4) + Data(count: 4))
        bodies.append(body)
    }
    return table + bodies
}
private func factoryBWC2(_ table: Data, duplicate: Bool = false) throws -> Data {
    let record = seq([integer(try Data("OCA2".utf8).uint(0, 4)), ascii("."), der(4, table)])
    let wcal = seq([integer(try Data("WCAL".utf8).uint(0, 4)), ascii("."), der(4, Data("BLOB".utf8) + Data(count: 12))])
    let contents = der(0x31, record + (duplicate ? record : Data()) + wcal)
    let extended = Data([0xff, 0x85, 0x9a, 0xc1, 0x82, 0x59]) + Data(der(0x30, contents).dropFirst())
    let payload = seq([integer(try Data("BWC2".utf8).uint(0, 4)), integer(0x03000300), extended])
    return seq([ascii("IMG4"), seq([ascii("IM4P"), ascii("BWC2"), ascii("1.0"), der(4, payload)])])
}
@Test func j700GeneratesRadioCachesFromFactoryDataWithoutAnyCapturedFiles() throws {
    let factory = try factoryBWC2(factoryOCATable()), address = "021122334455"
    let files = try J700FactoryCalibration.generate(factory: factory, address: address)
    #expect(files.count == 2)
    #expect(try files[0].data.uint(16, 4) == 23)
    #expect(try files[1].data.uint(14, 2) == 7)
    let temp = try TemporaryDirectory()
    for file in files { try write(file.data, to: temp.url.appending(file.name)) }
    let validated = try J700FirmwareCollectors.validateCalibration(files, address: address, factory: factory)
    #expect(validated.map(\.data) == files.map(\.data))
    let another = try J700FactoryCalibration.generate(factory: factory, address: "021122334456")
    #expect(another[0].name != files[0].name && another[0].data.subdata(in: 8..<14) != files[0].data.subdata(in: 8..<14))
}
@Test func j700FactoryParserRejectsCorruptionDuplicatesAndMalformedTables() throws {
    let table = factoryOCATable()
    #expect(throws: (any Error).self) { try J700FactoryCalibration.records(factoryBWC2(table, duplicate: true)) }
    var damaged = table; damaged[damaged.count - 1] ^= 1
    #expect(throws: (any Error).self) { try J700FactoryCalibration.sections(damaged) }
    damaged = table; damaged[23] = 0
    #expect(throws: (any Error).self) { try J700FactoryCalibration.sections(damaged) }
    #expect(throws: (any Error).self) { try J700FactoryCalibration.generate(factory: factoryBWC2(table), address: "000000000000") }
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["GRAVITY_J700_FACTORY_DIR"] != nil))
func j700RealFactoryMatchesPreviouslyQualifiedCaches() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GRAVITY_J700_FACTORY_DIR"]!)
    let factory = try #require(try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("BWC2-") })
    let cache = root.appending("calibration/mediatek/mt7932")
    let reference = try #require(try fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("calibration-") })
    let address = String(reference.deletingPathExtension().lastPathComponent.dropFirst("calibration-".count))
    let files = try J700FactoryCalibration.generate(factory: Data(contentsOf: factory), address: address)
    for file in files { #expect(try file.data == Data(contentsOf: cache.appending(file.name.components(separatedBy: "/").last!))) }
}
