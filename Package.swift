// swift-tools-version: 5.9
// SPDX-License-Identifier: GPL-2.0-only
import PackageDescription

let package = Package(
    name: "GravityInstaller",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GravityCore", targets: ["GravityCore"]),
        .executable(name: "gravity-installer", targets: ["GravityInstaller"])
    ],
    targets: [
        .target(name: "CInstallerSupport", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "GravityCore", dependencies: ["CInstallerSupport"], plugins: ["BoardDiscovery"]),
        .executableTarget(name: "BoardRegistryGenerator", path: "tools/BoardRegistryGenerator"),
        .plugin(name: "BoardDiscovery", capability: .buildTool(), dependencies: ["BoardRegistryGenerator"]),
        .executableTarget(name: "GravityInstaller", dependencies: ["GravityCore"]),
        .testTarget(name: "GravityCoreTests", dependencies: ["GravityCore"], path: "tests/GravityCoreTests")
    ]
)
