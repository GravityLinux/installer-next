// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Live image metadata. A CDN entry cannot add hardware or firmware support.
public enum ReleaseCatalog {
    public static let productionURL = URL(string: "https://cdn.gravitylinux.org/installer/installer_data.json")!
    public static let productionRepository = URL(string: "https://cdn.gravitylinux.org")!
    private struct Document: Decodable { let os_list: [SoftwareTemplate] }
    static func validateSource(_ url: URL) throws {
        try require(url.isFileURL || url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")), "Image metadata and downloads require HTTPS")
    }
    static func fetch(_ url: URL) throws -> Data {
        try validateSource(url)
        let data: Data
        if url.isFileURL { data = try Data(contentsOf: url) }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
            let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (body, response) = try HTTPRangeSource.request(request, session: session)
            try require(response.statusCode == 200, "Could not load available installation images from the CDN (HTTP \(response.statusCode)).")
            if let finalURL = response.url { try validateSource(finalURL) }
            data = body
        }
        try require(!data.isEmpty && data.count <= 8_000_000, "Invalid installation image metadata size")
        return data
    }
    static func candidates(_ data: Data, board: BoardProfile, developer: Bool, repository: URL) throws -> [String: SoftwareTemplate] {
        try validateSource(repository)
        let document = try JSONDecoder().decode(Document.self, from: data)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var result: [String: SoftwareTemplate] = [:]
        for template in document.os_list where template.supports(board) && (!template.expert || developer) {
            try require(!template.name.isEmpty, "An installation image is missing its name")
            try require((template.mode != .linux || !template.layout.isEmpty) && template.layout.filter { $0.expand == true }.count <= 1, "Invalid image partition definition")
            if template.mode == .uefi { try require(template.layout.count == 1, "UEFI-only installation requires exactly one ESP") }
            _ = try board.boot.downloadURL(template.boot_object, repository: repository)
            var total: Int64 = 0
            for part in template.layout {
                let bytes = try part.bytes, sum = total.addingReportingOverflow(bytes)
                try require(bytes > 0 && !sum.overflow && sum.partialValue <= Int64.max / 4, "Invalid image partition size")
                total = sum.partialValue
                try require(part.format == nil || part.format == "fat", "Unsupported partition format")
                if part.image != nil || part.source != nil { try require(template.package != nil, "Release image has no package") }
            }
            if let package = template.package { _ = try packageURL(package, repository: repository) }
            // All image/layout fields and the package host are bound to review.
            let identity = try encoder.encode(template) + Data(repository.absoluteString.utf8)
            result[board.id + ":cdn:" + identity.sha256] = template
        }
        return result
    }
    static func packageURL(_ value: String, repository: URL) throws -> URL {
        guard let url = URL(string: value, relativeTo: repository.appendingPathComponent("os/"))?.absoluteURL else { throw InstallerError("Invalid installation image URL") }
        try validateSource(url); return url
    }
}
