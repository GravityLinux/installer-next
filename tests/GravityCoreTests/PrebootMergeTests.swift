// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

@Test func externalPrebootMergeRefreshesAdministratorsAndKeepsOtherMetadata() throws {
    let temp = try TemporaryDirectory(), source = temp.url.appending("preboot/var"), dest = temp.url.appending("isc/var")
    try write(Data("new-admins".utf8), to: source.appending("db/AdminUserRecoveryInfo.plist"))
    try write(Data("old-admins".utf8), to: dest.appending("db/AdminUserRecoveryInfo.plist"))
    try write(Data("keep-existing".utf8), to: dest.appending("db/existing-record"))
    try write(Data("keep-other-tree".utf8), to: dest.appending("other/policy-record"))
    try copyMergingDirectory(source, dest)
    #expect(try Data(contentsOf: dest.appending("db/AdminUserRecoveryInfo.plist")) == Data("new-admins".utf8))
    #expect(try Data(contentsOf: dest.appending("db/existing-record")) == Data("keep-existing".utf8))
    #expect(try Data(contentsOf: dest.appending("other/policy-record")) == Data("keep-other-tree".utf8))
}

@Test func externalPrebootMergeCannotFollowADestinationDirectorySymlink() throws {
    let temp = try TemporaryDirectory(), source = temp.url.appending("source"), dest = temp.url.appending("dest"), outside = temp.url.appending("outside")
    try write(Data("new".utf8), to: source.appending("db/admins"))
    try write(Data("unchanged".utf8), to: outside.appending("admins")); try mkdir(dest)
    try fm.createSymbolicLink(at: dest.appending("db"), withDestinationURL: outside)
    #expect(throws: (any Error).self) { try copyMergingDirectory(source, dest) }
    #expect(try Data(contentsOf: outside.appending("admins")) == Data("unchanged".utf8))
}
