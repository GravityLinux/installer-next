// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

@Test func developerPreferencesPersistEveryOptionAndTheDisabledState() throws {
    let suite = "org.gravitylinux.installer.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(DeveloperPreferences.load(from: defaults) == DeveloperPreferences())
    var options = DeveloperOptions()
    options.customCDN = "https://cdn.example.test/testing"
    options.releaseChannel = "nightly"; options.bypassImageChecks = true
    options.allowUnsupportedMacs = true; options.verboseLogging = false; options.keepDownloads = true
    var saved = DeveloperPreferences(enabled: true, options: options)
    saved.save(to: defaults)
    let reopened = try #require(UserDefaults(suiteName: suite))
    #expect(DeveloperPreferences.load(from: reopened) == saved)
    saved.enabled = false; saved.save(to: defaults)
    let disabled = DeveloperPreferences.load(from: reopened)
    #expect(!disabled.enabled && disabled.options == options)
    #expect(defaults.dictionary(forKey: DeveloperPreferences.key)?.count == 8)
}

@Test func absentInvalidAndOlderDeveloperPreferencesUseSafeDefaults() throws {
    let suite = "org.gravitylinux.installer.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for invalid: Any in ["invalid", ["version": 99, "enabled": true], ["version": 1, "enabled": true, "customCDN": "ftp://invalid.example"], ["version": 1, "enabled": true, "releaseChannel": "unknown"]] {
        defaults.set(invalid, forKey: DeveloperPreferences.key)
        #expect(DeveloperPreferences.load(from: defaults) == DeveloperPreferences())
    }
    // Missing option keys keep their defaults, so adding an option does not
    // discard the user's existing opt-in when the installer is updated.
    defaults.set(["version": 1, "enabled": true], forKey: DeveloperPreferences.key)
    #expect(DeveloperPreferences.load(from: defaults) == DeveloperPreferences(enabled: true))
}
