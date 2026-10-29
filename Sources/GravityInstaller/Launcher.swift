// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import SwiftUI
import GravityCore

struct LaunchOptions {
    var configuration: EngineConfiguration
    var terminal = false, api = false, inspect = false, help = false
    var firmware: (URL, URL)?
    var firmwareBoardID: String?
    var handoff: URL?
    var handoffIPSW: URL?
    var previewDirectory: URL?
    var version = false
    var deploymentPath: URL?
    var expectedRelease: String?
    var updateChannel: String?
    var installerBase: URL?
    var latestURL: URL?
    var forceDeployment = false
    init(_ arguments: [String] = Array(CommandLine.arguments.dropFirst())) throws {
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
        let stage2 = resources.appendingPathComponent("stage2.json")
        configuration = EngineConfiguration(resourceDirectory: resources, appBundle: bundle, stage2URL: FileManager.default.fileExists(atPath: stage2.path) ? stage2 : nil)
        configuration.demo = Bundle.main.object(forInfoDictionaryKey: "GravityDemo") as? Bool == true
        if let bundle, let distribution = try InstallerDistribution.read(from: bundle) {
            configuration.developer = distribution.channel != "stable"
        }
        var i = 0
        func value() throws -> String {
            i += 1; guard i < arguments.count else { throw InstallerError("Missing value for \(arguments[i-1])") }; return arguments[i]
        }
        while i < arguments.count {
            switch arguments[i] {
            case "--tui": terminal = true
            case "--api": api = true
            case "--inspect": inspect = true
            case "--gui": break
            case "--demo": configuration.demo = true
            case "--developer": configuration.developer = true
            case "--no-developer": configuration.developer = false
            case "--resources": configuration.resourceDirectory = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--stage2":
                if i + 1 < arguments.count && !arguments[i+1].hasPrefix("--") { configuration.stage2URL = URL(fileURLWithPath: try value()).standardizedFileURL }
                else if configuration.stage2URL == nil && !configuration.demo { throw InstallerError("--stage2 requires the installed stage2.json path") }
                else if configuration.demo { configuration.stage2URL = URL(fileURLWithPath: "/demo/stage2.json") }
            case "--handoff-bundle": handoff = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--ipsw":
                let path = try value()
                handoffIPSW = path.contains("://") ? URL(string: path) : URL(fileURLWithPath: path)
                guard handoffIPSW != nil else { throw InstallerError("Invalid IPSW source") }
            case "--fwextract": firmware = (URL(fileURLWithPath: try value()), URL(fileURLWithPath: try value()))
            case "--board": firmwareBoardID = try value()
            case "--render-preview": previewDirectory = URL(fileURLWithPath: try value()); configuration.demo = true
            case "--version": version = true
            case "--deploy-app": deploymentPath = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--expected-release": expectedRelease = try value()
            case "--update-channel": updateChannel = try value()
            case "--installer-base": installerBase = URL(string: try value())
            case "--latest-url": latestURL = URL(string: try value())
            case "--force-deploy": forceDeployment = true
            case "--help", "-h": help = true
            default: throw InstallerError("Unknown option: \(arguments[i])")
            }
            i += 1
        }
        if handoff == nil && handoffIPSW != nil { throw InstallerError("--ipsw requires --handoff-bundle") }
        if handoff != nil && (firmware != nil || inspect || api || terminal || configuration.stage2URL != nil) { throw InstallerError("--handoff-bundle cannot be combined with another operation") }
        if firmwareBoardID != nil && firmware == nil { throw InstallerError("--board selects a firmware archive profile and requires --fwextract") }
    }
}

@main struct Launcher {
    private static var applicationLock: InstallerApplicationLock?
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        do {
            if CommandLine.arguments.dropFirst().first != "--deploy-app" {
                applicationLock = try InstallerApplicationLock.acquireIfInstalled(app: Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil)
            }
            let options = try LaunchOptions()
            if options.version { print(InstallerBuildInfo.current.description); return }
            if let destination = options.deploymentPath {
                guard let source = options.configuration.appBundle, let expectedRelease = options.expectedRelease,
                      let channel = options.updateChannel, let base = options.installerBase, let latest = options.latestURL else {
                    throw InstallerError("App deployment requires a packaged app, release ID, channel, and update endpoints")
                }
                let distribution = InstallerDistribution(installationPath: destination.path, channel: channel, installerBaseURL: base, latestURL: latest)
                let result = try InstallerApplication.install(source: source, destination: destination, expectedRelease: expectedRelease, distribution: distribution, force: options.forceDeployment)
                FileHandle.standardOutput.write(try JSONEncoder().encode(result) + Data([10])); return
            }
            if options.help { print(TerminalClient.usage); return }
            if options.api || options.terminal || options.inspect || options.firmware != nil || options.handoff != nil {
                Task {
                    do { try await TerminalClient.run(options); exit(0) }
                    catch { FileHandle.standardError.write(Data(("Error: \(error.localizedDescription)\n").utf8)); exit(1) }
                }
                dispatchMain()
            } else { GravityApp.main() }
        } catch { FileHandle.standardError.write(Data(("\(error.localizedDescription)\n\n\(TerminalClient.usage)\n").utf8)); exit(2) }
    }
}
