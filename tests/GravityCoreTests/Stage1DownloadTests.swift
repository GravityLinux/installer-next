// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

private let stage1Fixture = Data("fixture-m1n1-STACKBOT".utf8)

private final class Stage1Protocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stage1.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, checksum = url.pathExtension == "sha256"
        let status = url.path.contains("missing") ? 404 : 200
        let bytes: Data
        if checksum { bytes = Data(((url.path.contains("corrupt") ? String(repeating: "0", count: 64) : stage1Fixture.sha256) + "\n").utf8) }
        else { bytes = stage1Fixture }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func stage1DownloadsFromTheSelectedCDNWithoutAnyAppResources() throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Stage1Protocol.self]
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    let boot = BoardBootAssets(directory: "j700")
    let source = URL(string: "https://stage1.invalid/custom-cdn")!
    #expect(try boot.downloadURL("m1n1.bin", repository: source).absoluteString == "https://stage1.invalid/custom-cdn/boot/j700/m1n1.bin")
    let bytes = try Stage1Download.load(boot: boot, name: "m1n1.bin", repository: source, events: { _ in }, session: session)
    #expect(bytes == stage1Fixture)
    let vars = ["chosen.gravity,efi-system-partition=fixture", "chainload=fixture;m1n1/boot.bin"]
    #expect(try BootObject.variables(BootObject.build(bytes, variables: vars, alignment: 16384)) == vars)
    for name in ["missing.bin", "corrupt.bin"] {
        #expect(throws: (any Error).self) { try Stage1Download.load(boot: boot, name: name, repository: source, events: { _ in }, session: session) }
    }
}

@Test func stage1RequiresAMatchingChecksumAndRejectsInvalidDownloads() throws {
    let temp = try TemporaryDirectory(), boot = BoardBootAssets(directory: "j700")
    let url = try boot.downloadURL("stage1.bin", repository: temp.url)
    try write(stage1Fixture, to: url)
    func load() throws -> Data { try Stage1Download.load(boot: boot, name: "stage1.bin", repository: temp.url, events: { _ in }) }
    #expect(throws: (any Error).self) { try load() }
    for checksum in [stage1Fixture.sha256, stage1Fixture.sha256.uppercased() + "\n", stage1Fixture.sha256 + "  stage1.bin\n", stage1Fixture.sha256 + " *stage1.bin\n"] {
        try write(Data(checksum.utf8), to: url.appendingPathExtension("sha256"))
        #expect(try load() == stage1Fixture)
    }
    for invalid in ["", "<html>Error</html>", String(repeating: "0", count: 64), stage1Fixture.sha256 + "  another.bin", stage1Fixture.sha256 + "\n" + stage1Fixture.sha256] {
        try write(Data(invalid.utf8), to: url.appendingPathExtension("sha256"))
        #expect(throws: (any Error).self) { try load() }
    }
    try write(Data(stage1Fixture.sha256.utf8), to: url.appendingPathExtension("sha256"))
    for invalid in [Data(), Data(repeating: 0, count: Stage1Download.maximumBytes + 1)] {
        try write(invalid, to: url)
        #expect(throws: (any Error).self) { try load() }
    }
}

@Test func bootAssetPathsStayInsideTheSelectedRepository() throws {
    let source = URL(string: "https://cdn.example.test")!
    for invalid in ["", "../m1n1.bin", "/m1n1.bin", "https://other.test/m1n1.bin", "%2e%2e/m1n1.bin", "m1n1.bin?file=other", "a//m1n1.bin", "a/./m1n1.bin"] {
        #expect(throws: (any Error).self) { try BoardBootAssets().downloadURL(invalid, repository: source) }
    }
    #expect(throws: (any Error).self) { try BoardBootAssets(directory: "../other").downloadURL("m1n1.bin", repository: source) }
    #expect(throws: (any Error).self) { try BoardBootAssets().downloadURL("m1n1.bin", repository: URL(string: "http://public.example.test")!) }
    #expect(try BoardBootAssets().downloadURL("versions/stage1.bin", repository: source).absoluteString == "https://cdn.example.test/boot/versions/stage1.bin")
}

@Test func stage1PublishingPreparesStandaloneVerifiedContent() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let temp = try TemporaryDirectory(), supplied = temp.url.appending("qualified.bin"), output = temp.url.appending("cdn/boot/m1n1.bin")
    try write(stage1Fixture, to: supplied)
    _ = try SystemCommands().run("/usr/bin/env", ["M1N1_STAGE1=\(supplied.path)", "/bin/sh", repository.appending("tools/build-stage1.sh").path, output.path], input: nil)
    #expect(try Stage1Download.load(boot: BoardBootAssets(), name: "m1n1.bin", repository: temp.url.appending("cdn"), events: { _ in }) == stage1Fixture)
    #expect(try Data(contentsOf: supplied) == stage1Fixture)
}
