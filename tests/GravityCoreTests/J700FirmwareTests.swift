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
    #expect(try J700FirmwareCollectors.calibration(temp.url, address: address, factory: rf).count == 2)
    #expect(throws: (any Error).self) { try J700FirmwareCollectors.calibration(temp.url, address: "021122334456", factory: rf) }
    #expect(throws: (any Error).self) { try J700FirmwareCollectors.calibration(temp.url, address: address, factory: Data(repeating: 0, count: 32)) }
    try write(Data(precal.dropLast()), to: two)
    #expect(throws: (any Error).self) { try J700FirmwareCollectors.calibration(temp.url, address: address, factory: rf) }
}
