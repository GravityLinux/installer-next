# Gravity Linux installer

WIP: Experimental Gravity Linux installer

This will become the default installer of the Gravity Linux project.

## Build and local testing

Build on macOS with Swift 6:

```sh
./test.sh
swift run gravity-installer --demo
PREVIEW=1 sh scripts/build-app.sh
```

Preview apps always run in demo mode. Real app archives require the Gravity
artwork submodule and a qualified stage-1 bootloader for the target board:

```sh
git submodule update --init artwork
M1N1_STAGE1=/absolute/path/to/qualified/m1n1.bin ./build.sh
```

`BOOT_ASSETS_DIR` can supply a complete boot-assets directory instead. The
archive, checksum, version marker and generic bootstrap are written to
`releases/`. `VERSION` tracks the app version; archive IDs also identify the Git
revision. No remote publishing or deployment runs as part of this build.

For a full local test, serve these files from one directory:

```
releases/
  bootstrap.sh
  latest
  installer-<release>.tar.gz
  installer-<release>.tar.gz.sha256
  installer_data.json
  os/
    <packages referenced by the catalog>
```

The catalog must declare `supported_boards: ["j700"]` for a j700 image and use
boot objects included in the app. Relative package names are resolved under
`os/`; absolute package URLs are also supported. The host must support HEAD and
HTTP byte ranges for OS archives. One local server option on macOS is:

```sh
ruby -run -e httpd -- --bind-address=127.0.0.1 --port=5050 ./releases
```

On the Neo, either run that server locally or forward the server's port from
the build Mac in a separate Terminal window:

```sh
ssh -N -L 5050:127.0.0.1:5050 USER@BUILD_MAC
```

Then install/update the persistent app and launch the GUI:

```sh
curl -fsSL http://127.0.0.1:5050/bootstrap.sh | \
  INSTALLER_BASE=http://127.0.0.1:5050 INSTALLER_CHANNEL=development sh
```

For the TUI, replace the final `sh` with `sh -s -- --tui`. `--demo` previews the
interface, `--update` updates without launching, and `--version` prints the
installed version. The bootstrap saves its download configuration in the app;
later launches do not need the server's temporary files. The development channel
enables developer-only boards such as j700.

`INSTALLER_BASE` is required for downloads. By default the catalog is
`$INSTALLER_BASE/installer_data.json` and the image repository is
`$INSTALLER_BASE`. Override them with `INSTALLER_DATA` and `REPO_BASE` on the `sh`
process. Direct launches accept `--catalog URL_OR_PATH --repository URL`.
There are no built-in catalog/image hosting defaults. Local HTTP is allowed on
loopback; use an SSH tunnel or HTTPS when the server is on another computer.

Only Gravity installer/OS artifacts belong on this server. Apple restore images
are downloaded directly from Apple. Per-device firmware and calibration are
collected on the target Mac, and the generated firmware bundle stays local.

The only GitHub automation is a macOS test and preview-packaging check.

## Board support and firmware qualification

Boards use their product numbers throughout the app, API and source files:
`j773g` is enabled normally; `j700` is experimental and requires developer mode.
Its exact hardware match is `j700ap`, chip `0x8140`, board `0x64`.
Enable Developer Options in the GUI or pass `--developer` in the TUI/CLI.
`--no-developer` explicitly disables it, including on a development channel.

Unknown boards show a dedicated unsupported-board screen before authorization or
downloads. Developer-only boards show an explanation and a Developer Options
button. Developer mode never bypasses device, chip, board ID or firmware checks.
The JSON Lines API exposes the same read-only `checkBoardSupport` method, and
board errors include a structured `boardSupport` object with the reason, product
number, hardware identity and available boards.

To add a board, add **one or two files**:

1. `Sources/GravityCore/Boards/Profiles/J<number>.swift`, defining
   `enum J<number>` with `static let profile: BoardProfile`. Set the lowercase
   product number as `id`, exact hardware match, restore pins, boot assets,
   presentation details and any storage policy in that profile. Use
   `availability: .developer` until support is ready for normal users.
2. If its firmware needs different handling, add `Boards/J<number>Firmware.swift`
   implementing `BoardFirmwareLoading`. Existing loaders can be reused.

The SwiftPM `BoardDiscovery` plugin automatically registers every profile file.
There is no central board list or per-board change to the package manifest,
installer engine, GUI or TUI. Presentation gets its product number directly from
the profile ID. Shared restore definitions can be reused or a new restore can be
declared in the board's profile file. Catalog entries and bundled boot assets
still need to match the board, and hardware support needs device qualification.
Developer selection is saved for recovery finalization, so the second stage
retains the choice made when installing.

The j700 collector packages MT7932 firmware, the MT793B B1 upload payload and
IMX558 camera setfile. It archives factory BWC2 data, AID44 audio tuning and
selected restore firmware for later rebuilds. Resident AOP/PMP/ISP/DCP/GPU
firmware is supplied by the selected restore and iBoot, not uploaded by the
installer firmware package.

The j700 loader reads its BWC2 factory record from
`/System/Volumes/Hardware/FactoryData/System/Library/Caches/com.apple.factorydata`
and its Wi-Fi MAC from the live device tree. It validates the OCA2 section table,
checks section checksums/bounds, and generates the Linux startup calibration and
operating precal caches locally. No captured files or calibration in the app
bundle are required. The current operating bank deliberately follows the Linux
driver's qualified 6 GHz group 28 policy; it does not claim general channel
coverage. The original factory record is saved in the private firmware archive
so rebuilds do not depend on macOS still being available.

The packaged executable can qualify collection without installing:

```sh
"Gravity Installer.app/Contents/MacOS/gravity-installer" \
  --developer \
  --handoff-bundle "$HOME/neo-handoff"
```

An optional `--ipsw URL_OR_PATH` selects a locally cached copy of the qualified
restore. The profile still enforces the restore identity and recovery hashes.
Only localhost HTTP is allowed for development; other downloads require HTTPS.

This command does not partition disks or register a boot object. It produces
`firmware.tar`, `firmware.cpio`, `all_firmware.tar.gz`, a manifest and handoff
metadata. Success requires an archive-only rebuild to reproduce all three
firmware outputs byte for byte. Do not confuse this with qualification of
native Linux boot, OS installation, suspend or all wireless operating modes.
`j700` OS catalog entries must explicitly declare board support; the legacy
catalog fallback is retained for `j773g` only.

## Legal

Licensed under the GPL 2.0. This is a from scratch rewrite, but the existing
Python/CLI based Asahi installer under the MIT license was used as a reference.
Upstream attribution is retained in the existing [LICENSE](LICENSE) file and
included in the app's copy of that file.

Artwork, the bootloader submodule, and embedded design fonts retain their own
licenses.
