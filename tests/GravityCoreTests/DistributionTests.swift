// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

private final class DistributionFixture {
    let temporary: TemporaryDirectory
    let root: URL
    let server: URL
    let package: URL
    let capture: URL
    let downloads: URL
    let applications: URL
    let repository: URL
    let bootstrap: URL
    init() throws {
        temporary = try TemporaryDirectory(prefix: "gravity-distribution")
        root = temporary.url
        server = root.appending("release server"); package = root.appending("package"); capture = root.appending("capture"); downloads = root.appending("downloads")
        applications = root.appending("Applications")
        repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        bootstrap = repository.appending("scripts/bootstrap-prod.sh")
        for dir in [server, package, capture, downloads, applications] { try mkdir(dir) }
        try copy(repository.appending("install.sh"), package.appending("install.sh"))
        try copy(repository.appending("install.sh"), package.appending("Gravity Installer.app/Contents/Resources/launch.sh"))
        let binary = package.appending("Gravity Installer.app/Contents/MacOS/gravity-installer")
        let client = """
        #!/bin/sh
        set -eu
        if [ "${1:-}" = --deploy-app ]; then
            source_app=$(cd "$(dirname "$0")/../.." && pwd)
            /usr/bin/ditto "$source_app" "$2"
            printf '{"status":"installed","build":{"version":"0.1.0"}}\n'
            exit 0
        fi
        if [ "${1:-}" = --version ]; then printf 'Gravity Installer 0.1.0 (fixture-v1)\n'; exit 0; fi
        printf '%s\n' "$0" > "$CAPTURE_DIR/executable"
        printf '%s\n' "$@" > "$CAPTURE_DIR/arguments"
        mode=gui
        for argument in "$@"; do
            case "$argument" in --tui) mode=tui ;; --api) mode=api ;; esac
        done
        printf '%s\\n' "$mode" > "$CAPTURE_DIR/mode"
        case "$mode" in
            tui)
                test -t 0 && test -t 1
                printf 'Enter username: '
                read -r answer
                printf '%s' "$answer" > "$CAPTURE_DIR/answer"
                ;;
            api) cat > "$CAPTURE_DIR/stdin" ;;
        esac
        """
        try write(Data(client.utf8), to: binary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try write(Data("fixture-v1\n".utf8), to: server.appending("latest"))
        try write(Data("{}\n".utf8), to: server.appending("installer_data.json"))
        let archive = server.appending("installer-fixture-v1.tar.gz")
        _ = try SystemCommands().run("/usr/bin/tar", ["-czf", archive.path, "-C", package.path, "."], input: nil)
        try write(Data("\(checksums(archive).sha256)  installer-fixture-v1.tar.gz\n".utf8), to: server.appending("installer-fixture-v1.tar.gz.sha256"))
    }
    var environment: [String] {
        ["INSTALLER_BASE=\(server.absoluteString)", "INSTALLER_DATA=\(server.appending("installer_data.json").absoluteString)", "TMPDIR=\(downloads.path)", "CAPTURE_DIR=\(capture.path)", "GRAVITY_APPLICATIONS_DIR=\(applications.path)"]
    }
}

@Test func pipedBootstrapDefaultsToGUIAndVerifiesArchive() throws {
    let fixture = try DistributionFixture()
    let output = try SystemCommands().run("/usr/bin/env", fixture.environment + ["/bin/sh", "-s", "--", "--demo"], input: Data(contentsOf: fixture.bootstrap))
    #expect(String(decoding: output, as: UTF8.self).contains("installed at"))
    #expect(try String(contentsOf: fixture.capture.appending("mode")) == "gui\n")
    let args = try String(contentsOf: fixture.capture.appending("arguments"))
    #expect(args.contains("--demo\n"))
    #expect(try String(contentsOf: fixture.capture.appending("executable")).hasPrefix(fixture.applications.path))
    #expect(try fm.contentsOfDirectory(atPath: fixture.downloads.path).isEmpty)
}
@Test func curlPipedBootstrapReconnectsTUIToControllingTerminal() throws {
    let fixture = try DistributionFixture()
    func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let runner = fixture.root.appending("run-bootstrap.sh")
    let exports = fixture.environment.map { "export " + quote($0) }.joined(separator: "\n")
    let script = "#!/bin/sh\nset -eu\n" + exports + "\n/usr/bin/curl -fsSL " + quote(fixture.bootstrap.absoluteString) + " | /bin/sh -s -- --demo --tui\n"
    try write(Data(script.utf8), to: runner)
    try SystemCommands().authenticated("/bin/sh", [runner.path], credentials: Credentials(username: "fixture-user", password: "unused"))
    #expect(try String(contentsOf: fixture.capture.appending("mode")) == "tui\n")
    #expect(try String(contentsOf: fixture.capture.appending("answer")) == "fixture-user")
}
@Test func launchScriptPreservesAPIStandardInput() throws {
    let fixture = try DistributionFixture(), input = Data("{\"id\":\"fixture\",\"method\":\"inspect\"}\n".utf8)
    _ = try SystemCommands().run("/usr/bin/env", fixture.environment + ["/bin/sh", fixture.package.appending("install.sh").path, "--demo", "--api"], input: input)
    #expect(try String(contentsOf: fixture.capture.appending("mode")) == "api\n")
    #expect(try Data(contentsOf: fixture.capture.appending("stdin")) == input)
}
@Test func bootstrapRefusesCorruptDownloadBeforeLaunching() throws {
    let fixture = try DistributionFixture()
    try write(Data("corrupt archive".utf8), to: fixture.server.appending("installer-fixture-v1.tar.gz"))
    #expect(throws: (any Error).self) {
        try SystemCommands().run("/usr/bin/env", fixture.environment + ["/bin/sh", "-s", "--", "--demo"], input: Data(contentsOf: fixture.bootstrap))
    }
    #expect(!fm.fileExists(atPath: fixture.capture.appending("arguments").path))
}
@Test func bootstrapCanUpdateWithoutLaunchingAndReportVersionOffline() throws {
    let fixture = try DistributionFixture()
    let output = try SystemCommands().run("/usr/bin/env", fixture.environment + ["/bin/sh", "-s", "--", "--update"], input: Data(contentsOf: fixture.bootstrap))
    #expect(String(decoding: output, as: UTF8.self).contains("0.1.0: installed at"))
    #expect(fm.fileExists(atPath: fixture.applications.appending("Gravity Installer.app/Contents/MacOS/gravity-installer").path))
    #expect(!fm.fileExists(atPath: fixture.capture.appending("mode").path))
    #expect(try fm.contentsOfDirectory(atPath: fixture.downloads.path).isEmpty)
    try fm.removeItem(at: fixture.server)
    let version = try SystemCommands().run("/usr/bin/env", fixture.environment + ["/bin/sh", "-s", "--", "--version"], input: Data(contentsOf: fixture.bootstrap))
    #expect(String(decoding: version, as: UTF8.self).contains("Gravity Installer 0.1.0 (fixture-v1)"))
}
@Test func bootstrapCanCheckLatestWithoutDownloadingTheApp() throws {
    let fixture = try DistributionFixture()
    try fm.removeItem(at: fixture.server.appending("installer-fixture-v1.tar.gz"))
    let output = try SystemCommands().run("/usr/bin/env", fixture.environment + ["/bin/sh", "-s", "--", "--check-update"], input: Data(contentsOf: fixture.bootstrap))
    #expect(String(decoding: output, as: UTF8.self).contains("Latest installer release: fixture-v1"))
    #expect(try fm.contentsOfDirectory(atPath: fixture.applications.path).isEmpty)
    #expect(try fm.contentsOfDirectory(atPath: fixture.downloads.path).isEmpty)
}
