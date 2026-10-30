// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

private func multitouchPayload(_ family: String) throws -> Data {
    let commands: [[String: Any]] = [
        ["Type": "Config", "Interface Config": [["bInterfaceNumber": 1]]]
    ]
    let xml = try PropertyListSerialization.data(fromPropertyList: [family: commands], format: .xml, options: 0)
    return seq([ascii("IM4P"), ascii("mtfw"), ascii("1"), der(4, xml)])
}

@Test func multitouchPackagesBothTrackpadFamilies() throws {
    for (machine, family) in [("j700", "C1FE0,0"), ("j773g", "C1FD0,0")] {
        let temp = try TemporaryDirectory()
        try write(multitouchPayload(family), to: temp.url.appending("\(machine)/Multitouch.im4p"))
        let files = try Multitouch.files(temp.url, requireTrackpadFor: machine)
        #expect(files.count == 1)
        #expect(files[0].name == "apple/tpmtfw-\(machine).bin")
        #expect(files[0].data.prefix(4) == Data("HIDF".utf8))
        let offset = Int(try files[0].data.uint(16, 4))
        #expect(files[0].data[32 + offset] == 0)
    }
}

@Test func multitouchRejectsMissingRequiredBoardFirmware() throws {
    let temp = try TemporaryDirectory()
    #expect(try Multitouch.files(temp.url).isEmpty)
    #expect(throws: (any Error).self) {
        try Multitouch.files(temp.url, requireTrackpadFor: "j700")
    }
    try write(multitouchPayload("UNSUPPORTED"), to: temp.url.appending("j700/Multitouch.im4p"))
    #expect(throws: (any Error).self) {
        try Multitouch.files(temp.url, requireTrackpadFor: "j700")
    }
}
