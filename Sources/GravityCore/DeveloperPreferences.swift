// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Per-user preferences shared by the GUI, TUI and API. A single preferences
/// record keeps the enable flag and its options together across app updates.
public struct DeveloperPreferences: Equatable, Sendable {
    public var enabled: Bool
    public var options: DeveloperOptions
    public static let domain = InstallerBuildInfo.bundleIdentifier
    public static let key = "developerSettings"

    public init(enabled: Bool = false, options: DeveloperOptions = DeveloperOptions()) {
        self.enabled = enabled; self.options = options
    }

    public static func load(from defaults: UserDefaults = UserDefaults(suiteName: domain)!) -> DeveloperPreferences {
        guard let saved = defaults.dictionary(forKey: key), saved["version"] as? Int == 1 else { return DeveloperPreferences() }
        var options = DeveloperOptions()
        options.customCDN = saved["customCDN"] as? String ?? options.customCDN
        options.releaseChannel = saved["releaseChannel"] as? String ?? options.releaseChannel
        options.bypassImageChecks = saved["bypassImageChecks"] as? Bool ?? options.bypassImageChecks
        options.allowUnsupportedMacs = saved["allowUnsupportedMacs"] as? Bool ?? options.allowUnsupportedMacs
        options.verboseLogging = saved["verboseLogging"] as? Bool ?? options.verboseLogging
        options.keepDownloads = saved["keepDownloads"] as? Bool ?? options.keepDownloads
        guard (try? options.sources(defaultCatalog: ReleaseCatalog.productionURL, defaultRepository: ReleaseCatalog.productionRepository)) != nil else { return DeveloperPreferences() }
        return DeveloperPreferences(enabled: saved["enabled"] as? Bool ?? false, options: options)
    }

    public func save(to defaults: UserDefaults = UserDefaults(suiteName: domain)!) {
        defaults.set(["version": 1, "enabled": enabled, "customCDN": options.customCDN,
            "releaseChannel": options.releaseChannel, "bypassImageChecks": options.bypassImageChecks,
            "allowUnsupportedMacs": options.allowUnsupportedMacs, "verboseLogging": options.verboseLogging,
            "keepDownloads": options.keepDownloads], forKey: Self.key)
    }
}
