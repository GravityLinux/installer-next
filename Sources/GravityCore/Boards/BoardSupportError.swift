// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Shared by the GUI's unsupported-board screen, terminal messages and API.
public struct BoardSupportError: Error, LocalizedError, Codable, Sendable {
    public enum Reason: String, Codable, Sendable { case unsupported, developerRequired }
    public let reason: Reason
    public let productNumber: String
    public let hardware: HardwareIdentity?
    public let supportedBoards: [String]
    public init(reason: Reason, productNumber: String, hardware: HardwareIdentity? = nil, supportedBoards: [String]) {
        self.reason = reason; self.productNumber = productNumber; self.hardware = hardware; self.supportedBoards = supportedBoards
    }
    public var title: String { reason == .developerRequired ? "This board requires developer mode" : "This board isn’t supported yet" }
    public var errorDescription: String? {
        if reason == .developerRequired { return "Board \(productNumber) is experimental. Enable Developer Options and select Allow unsupported Macs, or pass --developer in Terminal to use its board profile. Hardware and firmware checks still apply." }
        let supported = supportedBoards.isEmpty ? "No boards are enabled in this mode." : "Supported boards: \(supportedBoards.joined(separator: ", "))."
        return "Gravity Linux does not yet support board \(productNumber). \(supported) Developer mode cannot enable a board without a matching profile."
    }
}
