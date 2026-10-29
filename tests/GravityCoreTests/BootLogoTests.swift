// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

@Test func logoBuilderWorksWithBothImageMagickCommandNames() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for converter in ["magick", "convert"] {
        let temp = try TemporaryDirectory(), bin = temp.url.appending("bin"), boot = temp.url.appending("m1n1.bin")
        let command = bin.appending(converter), artwork = temp.url.appending("artwork")
        try write(Data("#!/bin/sh\nfor argument in \"$@\"; do output=$argument; done\nprintf RGBA > \"${output#rgba:}\"\n".utf8), to: command)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        try write(Data("BOOT".utf8), to: boot)
        _ = try SystemCommands().run("/usr/bin/env", ["PATH=\(bin.path):/usr/bin:/bin", "/bin/sh", repository.appending("tools/append-boot-logo.sh").path, boot.path, artwork.path], input: nil)
        #expect(try Data(contentsOf: boot) == Data("BOOTm1n1_logo_256128RGBARGBA".utf8))
        // A conversion failure must leave the bootloader unchanged.
        try write(Data("#!/bin/sh\nexit 1\n".utf8), to: command)
        let before = try Data(contentsOf: boot)
        #expect(throws: (any Error).self) {
            try SystemCommands().run("/usr/bin/env", ["PATH=\(bin.path):/usr/bin:/bin", "/bin/sh", repository.appending("tools/append-boot-logo.sh").path, boot.path, artwork.path], input: nil)
        }
        #expect(try Data(contentsOf: boot) == before)
    }
}
