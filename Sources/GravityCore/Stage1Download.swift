// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Stage1 is release content from the selected CDN, never an app resource.
/// Keep the verified bytes for the whole operation so no later request can
/// change the bootloader after partition changes have begun.
enum Stage1Download {
    static let maximumBytes = 16 * 1024 * 1024

    static func load(boot: BoardBootAssets, name: String, repository: URL, events: EventSink, session: URLSession? = nil) throws -> Data {
        let url = try boot.downloadURL(name, repository: repository)
        events(InstallEvent(.stage1, detail: url.lastPathComponent))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        let owned = session == nil
        let session = session ?? URLSession(configuration: configuration)
        defer { if owned { session.invalidateAndCancel() } }
        let checksum = try fetch(url.appendingPathExtension("sha256"), limit: 4096, session: session)
        let bytes = try fetch(url, limit: maximumBytes, session: session)
        try verify(bytes, checksum: checksum, name: name)
        events(InstallEvent(.stage1, fraction: 1, detail: url.lastPathComponent))
        return bytes
    }

    private static func fetch(_ url: URL, limit: Int, session: URLSession) throws -> Data {
        try ReleaseCatalog.validateSource(url)
        let bytes: Data
        if url.isFileURL {
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            bytes = try file.read(upToCount: limit + 1) ?? Data()
        } else {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let (data, response) = try HTTPRangeSource.request(request, session: session)
            if let final = response.url { try ReleaseCatalog.validateSource(final) }
            try require(response.statusCode == 200, "Could not download stage1 from \(url.absoluteString) (HTTP \(response.statusCode))")
            bytes = data
        }
        try require(!bytes.isEmpty && bytes.count <= limit, "Invalid stage1 download size: \(url.lastPathComponent)")
        return bytes
    }

    private static func verify(_ bytes: Data, checksum: Data, name: String) throws {
        guard let text = String(data: checksum, encoding: .utf8) else { throw InstallerError("Invalid stage1 SHA-256 file") }
        let lines = text.split(whereSeparator: { $0.isNewline })
        try require(lines.count == 1, "Stage1 requires exactly one SHA-256 checksum")
        let fields = lines[0].split(whereSeparator: { $0.isWhitespace })
        guard let digest = fields.first else { throw InstallerError("Missing stage1 SHA-256 checksum") }
        try require(digest.count == 64 && digest.allSatisfy { "0123456789abcdefABCDEF".contains($0) } && fields.count <= 2, "Invalid stage1 SHA-256 checksum")
        if fields.count == 2 {
            let filename = fields[1].hasPrefix("*") ? fields[1].dropFirst() : fields[1][...]
            try require(filename == URL(fileURLWithPath: name).lastPathComponent, "The stage1 checksum names another file")
        }
        try require(bytes.sha256 == digest.lowercased(), "Stage1 SHA-256 mismatch; no partition changes have been made")
    }
}
