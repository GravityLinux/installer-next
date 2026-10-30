// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

@Test func developerOptionsRequireExplicitOptInAndKeepAppleVerificationSeparate() throws {
    var config = EngineConfiguration(resourceDirectory: URL(fileURLWithPath: "/unused"))
    #expect(!config.developer && !config.boardDeveloper && !config.bypassImageChecks && config.downloadCache == nil)
    config.developerOptions.allowUnsupportedMacs = true; config.developerOptions.bypassImageChecks = true; config.developerOptions.keepDownloads = true
    #expect(!config.boardDeveloper && !config.bypassImageChecks && config.downloadCache == nil)
    config.developer = true
    #expect(config.boardDeveloper && config.bypassImageChecks && config.downloadCache != nil)
    let temp = try TemporaryDirectory(), zip = temp.url.appending("fixture.zip")
    try storedZIP(name: "root.img", data: Data("fixture image".utf8), badCRC: true).write(to: zip)
    // Only an explicitly opted-in Linux archive can bypass CRC checks. The
    // default ZIP reader used for Apple restore firmware still rejects it.
    #expect(try ZIPArchive(zip, verifyCRC: !config.bypassImageChecks).data("root.img") == Data("fixture image".utf8))
    #expect(throws: (any Error).self) { try ZIPArchive(zip).data("root.img") }
}

@Test func customCDNAndChannelSelectBothImageMetadataAndPackages() throws {
    var options = DeveloperOptions()
    let defaults = try options.sources(defaultCatalog: ReleaseCatalog.productionURL, defaultRepository: ReleaseCatalog.productionRepository)
    #expect(defaults.catalog == ReleaseCatalog.productionURL)
    options.customCDN = "http://127.0.0.1:5050"
    let stable = try options.sources(defaultCatalog: ReleaseCatalog.productionURL, defaultRepository: ReleaseCatalog.productionRepository)
    #expect(stable.catalog.absoluteString == "http://127.0.0.1:5050/installer/installer_data.json")
    #expect(try ReleaseCatalog.packageURL("fixture.zip", repository: stable.repository).absoluteString == "http://127.0.0.1:5050/os/fixture.zip")
    options.releaseChannel = "nightly"
    #expect(try options.sources(defaultCatalog: ReleaseCatalog.productionURL, defaultRepository: ReleaseCatalog.productionRepository).catalog.absoluteString == "http://127.0.0.1:5050/installer-dev/installer_data.json")
    options.customCDN = "ftp://invalid.example"
    #expect(throws: (any Error).self) { try options.sources(defaultCatalog: ReleaseCatalog.productionURL, defaultRepository: ReleaseCatalog.productionRepository) }
}

private final class RangeFixtureState: @unchecked Sendable {
    let lock = NSLock()
    var heads = 0, gets = 0, tag = "\"one\""
    func reply(head: Bool) -> String { lock.lock(); defer { lock.unlock() }; if head { heads += 1 } else { gets += 1 }; return tag }
    func changed() { lock.lock(); defer { lock.unlock() }; tag = "\"two\"" }
    var counts: [Int] { lock.lock(); defer { lock.unlock() }; return [heads, gets] }
}
private final class RangeFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = RangeFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "gravity-cache.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let head = request.httpMethod == "HEAD", tag = Self.state.reply(head: head)
        let headers = ["Content-Length": "100", "ETag": tag, "Content-Range": "bytes 0-99/100"]
        let response = HTTPURLResponse(url: request.url!, statusCode: head ? 200 : 206, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !head { client?.urlProtocol(self, didLoad: Data(repeating: 42, count: 100)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@Test func keptDownloadsReuseRangesOnlyWhileTheServerValidatorMatches() throws {
    let temp = try TemporaryDirectory(), url = URL(string: "https://gravity-cache.invalid/image.zip")!
    func source() throws -> HTTPRangeSource {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RangeFixtureProtocol.self]
        return try HTTPRangeSource(url, cacheDirectory: temp.url, session: URLSession(configuration: config))
    }
    let first = try source()
    #expect(try first.read(offset: 0, count: 100) == Data(repeating: 42, count: 100))
    let second = try source()
    #expect(try second.read(offset: 0, count: 100) == Data(repeating: 42, count: 100))
    #expect(RangeFixtureProtocol.state.counts == [2, 1])
    RangeFixtureProtocol.state.changed()
    let changed = try source()
    _ = try changed.read(offset: 0, count: 100)
    #expect(RangeFixtureProtocol.state.counts == [3, 2])
}
