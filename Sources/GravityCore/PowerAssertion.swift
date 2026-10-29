// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import IOKit.pwr_mgt

final class PowerAssertion {
    private var id: IOPMAssertionID = 0
    init() {
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                  IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                  "Installing Gravity Linux" as CFString, &id)
    }
    deinit { if id != 0 { IOPMAssertionRelease(id) } }
}
