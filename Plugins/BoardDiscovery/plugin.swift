// SPDX-License-Identifier: GPL-2.0-only
import PackagePlugin
import Foundation

/// Every product-number profile is registered at build time. Adding a board
/// never requires editing the package manifest or the core registry.
@main struct BoardDiscovery: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        var profiles: [Path] = []
        for file in target.sourceFiles {
            let url = URL(fileURLWithPath: file.path.string)
            if url.deletingLastPathComponent().lastPathComponent == "Profiles" && url.pathExtension == "swift" {
                profiles.append(file.path)
            }
        }
        profiles.sort { $0.string < $1.string }
        let output = context.pluginWorkDirectory.appending("DiscoveredBoards.swift")
        return [.buildCommand(displayName: "Discover board profiles",
            executable: try context.tool(named: "BoardRegistryGenerator").path,
            arguments: [output.string] + profiles.map { $0.string }, inputFiles: profiles, outputFiles: [output])]
    }
}
