// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

@Test func realIORegXMLWhitespaceIsPreserved() throws {
    let xml = Data("<?xml version=\"1.0\"?><plist version=\"1.0\">\r\n\t<dict><key>name</key><string>Neo\u{7}Board</string></dict></plist>".utf8)
    #expect(string(try MacSystem.deviceTree(xml)["name"]) == "Neo?Board")
    let wrapped = try PropertyListSerialization.data(fromPropertyList: [["name": "Neo"]], format: .xml, options: 0)
    #expect(string(try MacSystem.deviceTree(wrapped)["name"]) == "Neo")
}
