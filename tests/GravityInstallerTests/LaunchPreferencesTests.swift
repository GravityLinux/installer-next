// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
import GravityCore
@testable import GravityInstaller

private func savedDeveloperOptions() -> DeveloperPreferences {
    var options = DeveloperOptions()
    options.allowUnsupportedMacs = true; options.bypassImageChecks = true
    options.customCDN = "https://cdn.example.test/custom"; options.releaseChannel = "nightly"
    options.keepDownloads = true; options.verboseLogging = false
    return DeveloperPreferences(enabled: true, options: options)
}

@Test func everyClientRestoresSavedDeveloperOptionsAndSources() throws {
    let saved = savedDeveloperOptions()
    for arguments in [[], ["--tui"], ["--api"]] {
        let launch = try LaunchOptions(arguments, preferences: saved)
        let config = try launch.resolvedConfiguration()
        #expect(config.developer && config.boardDeveloper && config.bypassImageChecks)
        #expect(config.developerOptions == saved.options)
        #expect(config.catalogURL.absoluteString == "https://cdn.example.test/custom/installer-dev/installer_data.json")
        #expect(config.repositoryURL.absoluteString == "https://cdn.example.test/custom")
    }
}

@Test func explicitFlagsOverrideSavedSettingsWithoutChangingThem() throws {
    let saved = savedDeveloperOptions()
    let disabled = try LaunchOptions(["--tui", "--no-developer", "--verify-image-checks", "--discard-downloads"], preferences: saved).resolvedConfiguration()
    #expect(!disabled.developer && !disabled.boardDeveloper && !disabled.bypassImageChecks && disabled.downloadCache == nil)
    #expect(disabled.catalogURL == ReleaseCatalog.productionURL && disabled.repositoryURL == ReleaseCatalog.productionRepository)
    let explicitSources = try LaunchOptions(["--api", "--catalog", "https://explicit.test/data.json", "--repository", "https://explicit.test"], preferences: saved).resolvedConfiguration()
    #expect(explicitSources.catalogURL.absoluteString == "https://explicit.test/data.json")
    #expect(explicitSources.repositoryURL.absoluteString == "https://explicit.test")
    // GUI source selection uses the same resolver when the user disables or
    // re-enables Developer Options during a launch.
    let launch = try LaunchOptions([], preferences: saved)
    #expect(try launch.resolvedConfiguration(developer: false).repositoryURL == ReleaseCatalog.productionRepository)
    #expect(try launch.resolvedConfiguration(developer: true).repositoryURL.absoluteString == saved.options.customCDN)
    #expect(saved.enabled && saved.options.bypassImageChecks)
}

@Test func demoAndPreviewLaunchesIgnoreRealDeveloperSettings() throws {
    for arguments in [["--demo"], ["--render-preview", "/tmp/previews"], ["--check-window-close", "/tmp/window.json"]] {
        let config = try LaunchOptions(arguments, preferences: savedDeveloperOptions()).resolvedConfiguration()
        #expect(config.demo && !config.developer && config.developerOptions == DeveloperOptions())
        #expect(config.repositoryURL == ReleaseCatalog.productionRepository)
    }
}
