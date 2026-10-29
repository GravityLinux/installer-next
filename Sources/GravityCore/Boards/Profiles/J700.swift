// SPDX-License-Identifier: GPL-2.0-only
import Foundation

enum J700 {
    static let profile = BoardProfile(
        id: "j700", deviceClass: "j700ap", chipID: 0x8140, boardIDs: [0x64],
        minimumMacOS: "26.6", restore: QualifiedRestore.v26_6_2,
        firmwareMachine: "j700", firmware: J700Firmware(),
        presentation: BoardPresentation(symbol: "laptopcomputer", status: "Alpha",
            notes: "Experimental j700 support. Wi-Fi collection requires this radio’s validated calibration cache.",
            powerButtonHelp: "Hold the power button at the top-right of the keyboard until startup options appear.",
            postInstallNote: "Sleep and native boot still need qualification. Speaker playback retains the conservative driver volume cap."),
        availability: .developer)
}
