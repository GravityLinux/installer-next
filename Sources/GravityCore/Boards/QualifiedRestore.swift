// SPDX-License-Identifier: GPL-2.0-only
import Foundation

// This qualified universal recovery also has a J700 restore identity.
enum QualifiedRestore {
    static let v26_6_2 = RestoreProfile(
        version: "26.6.2",
        url: URL(string: "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-75212/A2A24B94-1FC1-45A3-93F7-C51B02AF1F4D/UniversalMac_26.6.2_25G83_Restore.ipsw")!,
        member: "022-22048-093.dmg.aea",
        decodedSHA256: "eeda386b1fb66a313cadef26e3e7ee06643d4d5ea8b3330a411a118ac7d14ed3",
        encoding: .aea(
            encryptedSHA256: "4e91f4949f0614de01f44434bce2a5a45b0e0a92ca0e3b06cd55c229752a9754",
            // Apple-published release material; original qualification provenance:
            // https://wkms-public.apple.com/fcs-keys/iH707G4WnpWgYOxDeMRHQUtlbIsfVaeIA86lDBYsT2U=
            key: "base64:WYNVRNc/IXaQQi1cN2hGFNsELwlDuMHjSRi97lyIQJo="),
        restoreBundleFallback: "restore")
}
