// SPDX-License-Identifier: GPL-2.0-only
import Foundation

enum J773g {
    static let restore = QualifiedRestore.v26_6_2

    static let profile = BoardProfile(
        id: "j773g", deviceClass: "j773gap", chipID: 0x8132,
        minimumMacOS: "26.5", restore: restore, firmwareMachine: "j773g",
        firmware: J773gFirmware(),
        presentation: BoardPresentation(symbol: "macmini", status: "Alpha",
            notes: "Boots and runs. Not ready to be a daily driver yet.",
            powerButtonHelp: "On your Mac mini, the power button is on the bottom, near the back-left corner.",
            postInstallNote: "Good to know in this alpha: sleep doesn’t work yet, so shut down when you’re done."),
        releases: [.bootloaderOnly])
}
