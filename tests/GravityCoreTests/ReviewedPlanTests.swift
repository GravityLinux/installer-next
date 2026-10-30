// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

@Test func reviewedPlanMatchesAcrossProcessesButRejectsChangedIntentOrDisk() async throws {
    let engine = InstallerEngine(configuration: EngineConfiguration(resourceDirectory: URL(fileURLWithPath: "/unused"), demo: true))
    var info = try await engine.inspect(); info.software = try await engine.availableSoftware()
    let selection = InstallSelection(targetID: info.targets[0].id, softwareID: info.software[0].id, bytes: 120_000_000_000)
    var reviewed = try await engine.plan(selection)
    reviewed.fingerprint = "reviewed-disk"
    func reconstructed(selection: InstallSelection? = nil, target: StorageTarget? = nil, fingerprint: String = "reviewed-disk") -> InstallPlan {
        InstallPlan(id: UUID().uuidString, selection: selection ?? reviewed.selection, target: target ?? reviewed.target,
            software: reviewed.software, macOSAfterBytes: reviewed.macOSAfterBytes, changes: reviewed.changes, fingerprint: fingerprint)
    }
    #expect(reviewed.hasSameReview(as: reconstructed()))
    let target = reviewed.target
    let lessFree = StorageTarget(id: target.id, name: target.name, kind: target.kind, totalBytes: target.totalBytes,
        freeBytes: target.freeBytes - 4096, maximumBytes: target.maximumBytes - 4096)
    #expect(reviewed.hasSameReview(as: reconstructed(target: lessFree)))
    #expect(!reviewed.hasSameReview(as: reconstructed(fingerprint: "changed-disk")))
    var changed = reviewed.selection; changed.bytes += 4096
    #expect(!reviewed.hasSameReview(as: reconstructed(selection: changed)))
    changed = reviewed.selection; changed.targetID = "another-partition"
    #expect(!reviewed.hasSameReview(as: reconstructed(selection: changed)))
    changed = reviewed.selection; changed.softwareID = "another-release"
    #expect(!reviewed.hasSameReview(as: reconstructed(selection: changed)))
}

@Test func privilegedCommitRejectsChangedReviewBeforeStartingInstallation() async throws {
    let engine = InstallerEngine(configuration: EngineConfiguration(resourceDirectory: URL(fileURLWithPath: "/unused"), demo: true))
    var info = try await engine.inspect(); info.software = try await engine.availableSoftware()
    var plan = try await engine.plan(InstallSelection(targetID: info.targets[0].id, softwareID: info.software[0].id, bytes: 120_000_000_000))
    plan.fingerprint = "changed-after-review"
    await #expect(throws: (any Error).self) {
        try await engine.installReviewed(plan, credentials: Credentials(username: "demo", password: "demo"))
    }
}
