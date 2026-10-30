// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

private func image(_ name: String = "Fixture Linux", boards: [String]? = nil, expert: Bool = false, package: String = "fixture.zip") -> [String: Any] {
    var value: [String: Any] = ["name": name, "package": package, "supported_fw": ["26.6.2"], "expert": expert,
        "partitions": [["name": "Root", "type": "Linux", "size": "5GB", "expand": true, "image": "root.img"]]]
    if let boards { value["supported_boards"] = boards }; return value
}
private func candidates(_ entries: [[String: Any]], board: BoardProfile = J773g.profile, developer: Bool = false, repository: URL = ReleaseCatalog.productionRepository) throws -> [String: SoftwareTemplate] {
    try ReleaseCatalog.candidates(JSONSerialization.data(withJSONObject: ["os_list": entries]), board: board, developer: developer, repository: repository)
}

@Test func legacyM4ImageDoesNotBecomeANeoCandidate() throws {
    let legacy = image()
    #expect(try candidates([legacy]).count == 1)
    #expect(try candidates([legacy], board: J700.profile, developer: true).isEmpty)
    let neo = image("Neo Linux", boards: ["j700"])
    #expect(try candidates([neo], board: J700.profile, developer: true).count == 1)
    #expect(try candidates([neo]).isEmpty)
    var mismatch = neo; mismatch["supported_fw"] = ["another-build"]
    #expect(try candidates([mismatch], board: J700.profile, developer: true).isEmpty)
    #expect(try candidates([image(expert: true)]).isEmpty)
    #expect(try candidates([image(expert: true)], developer: true).count == 1)
}

@Test func imageReviewIdentityIncludesTheArtifactAndLayoutButNotListOrder() throws {
    let first = image(), second = image("Another Linux", package: "another.zip")
    let original = try candidates([first])
    #expect(Set(try candidates([first, second]).keys) == Set(try candidates([second, first]).keys))
    #expect(Set(original.keys) != Set(try candidates([image(package: "new-image.zip")]).keys))
    var changed = first
    changed["partitions"] = [["name": "Root", "type": "Linux", "size": "6GB", "expand": true, "image": "root.img"]]
    #expect(Set(original.keys) != Set(try candidates([changed]).keys))
    #expect(Set(original.keys) != Set(try candidates([first], repository: URL(string: "https://another.example")!).keys))
}

@Test func imageMetadataReloadsAndPackagesUseTheExistingCDNLayout() throws {
    let temp = try TemporaryDirectory(), url = temp.url.appending("installer_data.json")
    func publish(_ entry: [String: Any]) throws { try write(JSONSerialization.data(withJSONObject: ["os_list": [entry]]), to: url) }
    try publish(image())
    let first = try ReleaseCatalog.candidates(ReleaseCatalog.fetch(url), board: J773g.profile, developer: false, repository: ReleaseCatalog.productionRepository)
    try publish(image("New release", package: "new.zip"))
    let refreshed = try ReleaseCatalog.candidates(ReleaseCatalog.fetch(url), board: J773g.profile, developer: false, repository: ReleaseCatalog.productionRepository)
    #expect(Set(first.keys) != Set(refreshed.keys))
    #expect(try ReleaseCatalog.packageURL("fixture.zip", repository: ReleaseCatalog.productionRepository).absoluteString == "https://cdn.gravitylinux.org/os/fixture.zip")
    #expect(try ReleaseCatalog.packageURL("https://images.example/f.zip", repository: ReleaseCatalog.productionRepository).absoluteString == "https://images.example/f.zip")
    #expect(throws: (any Error).self) { try ReleaseCatalog.packageURL("http://insecure.example/f.zip", repository: ReleaseCatalog.productionRepository) }
    #expect(throws: (any Error).self) { try candidates([image(package: "ftp://invalid.example/f.zip")]) }
    #expect(throws: (any Error).self) { try ReleaseCatalog.candidates(Data("{}".utf8), board: J773g.profile, developer: false, repository: ReleaseCatalog.productionRepository) }
}
