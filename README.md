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
```

Available OS images are queried live from the Gravity CDN. Image archive hosts
must support HEAD and HTTP byte ranges. One local app-artifact server option on
macOS is:

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
later launches do not need the server's temporary files. Developer Options starts
disabled on ordinary launches, including development channel builds. Enable it
explicitly to test experimental features.

`INSTALLER_BASE` selects the app-update artifacts. Available OS images and their
layouts are fetched from `https://cdn.gravitylinux.org/installer/installer_data.json`;
relative package filenames resolve under `https://cdn.gravitylinux.org/os/`.
`INSTALLER_DATA` and `REPO_BASE` override those two OS sources during bootstrap,
and the app saves the values for subsequent launches. Direct app launches accept
`--catalog URL_OR_PATH --repository URL_OR_PATH` for local image testing. Local
HTTP is allowed on loopback; use an SSH tunnel or HTTPS for another computer.

The CDN is first queried when the user opens Choose your desktop, after local
inspection and partition selection. A custom CDN entered in Developer Options
therefore applies before the first image request. Publishing metadata alone
does not enable hardware absent from the compiled registry.

Hardware detection, developer gates, firmware loaders, restore qualification and
storage constraints are compiled into the installer. Adding board support needs
a new installer version; publishing a compatible image candidate needs only a
CDN metadata/image update. The CDN does not supply executable board plugins.

Only Gravity installer/OS artifacts belong on this server. Apple restore images
are downloaded directly from Apple. Per-device firmware and calibration are
collected on the target Mac, and the generated firmware bundle stays local.

The only GitHub automation is a macOS test and preview-packaging check.

## Credentials and design inventory

The original HTML design is preserved at `docs/design/reference.html`. The
screen-by-screen review is `docs/design/audit.csv`. Generate the native views
with `swift run gravity-installer --render-preview dist/design-review/current`.
The UI uses the design's Geist fonts, shipped under the bundled font license.
Preview rendering also checks the real Developer Options window for extra
title-bar space and verifies that Done leaves the installer open even when the
installer has keyboard focus. Developer Options sizes itself to its contents.

Startup inspection and review use read-only queries and never mount volumes or
read privileged boot policy. Ask for credentials after Review. The GUI/TUI starts
one private privileged process for that install session; the supplied credentials
are held in memory for the Apple tools and are cleared after the stage completes.
The privileged process reconstructs and compares the reviewed plan before making
changes. Normal macOS uses the administrator account currently logged in;
recovery runs as root and accepts the paired macOS administrator's credentials.
1TR is a new boot session and asks once again. Passwords are never written to
arguments, environment variables, state files or logs.

[The exception-state inventory](docs/installer-exception-states.csv) lists every
identified error/alternate-flow family, its current UI surface, mutation state,
possible actions and design notes. Some rows identify states that still need a
dedicated presentation; the list is a design specification, not an assertion that
all variants already have finished UI. There is no separate Authorize screen.

In the JSON Lines API, `inspect` returns local hardware/storage information
without fetching image metadata; call `listSoftware` on entering software
selection, then `plan` and `install`. The privileged process checks the selected
CDN entry again before changing the disk. The TUI follows the same sequence.

Developer Options offers a custom CDN, Stable/Nightly image channels, explicit
experimental-board access, Linux-image CRC bypass, detailed logging and local
download retention. Apple recovery hashes, firmware validation, archive bounds
and board identity checks always apply. Retained archive ranges are private to
this Mac and reused only when the server validator and length still match.
The partition slider represents the macOS/Linux boundary across their combined
space. With no unallocated space it starts at the far right with Linux at zero.
With adjacent unallocated space it starts proportionally at the current macOS
boundary, initially giving Linux that free space. Moving left gives Linux more;
moving right gives macOS more, growing macOS into unused space when needed.
There are no separate storage-choice rows. The default leaves **2 GB free inside macOS**,
subject to APFS's reported hard minimum. The preferred-size recommendation does
not impose an additional reserve. Selecting exactly the existing free extent does
not resize macOS. Continue is disabled for an undersized Linux allocation; a
separate capacity check reports when the maximum available space is insufficient.
These invalid-state presentations still need a design pass. UEFI/bootloader-only modes retain their stub/ESP-only layouts
and leave the rest free for a future OS.

The current developer-gated board screen is an unapproved placeholder awaiting a
design pass; its presentation and entry flow are tracked in the exception-state
inventory. Board gating remains in place pending that design work.

## Board support and firmware qualification

Boards use their product numbers throughout the app, API and source files:
`j773g` is enabled normally; `j700` is experimental and requires developer mode.
Its exact hardware match is `j700ap`, chip `0x8140`, board `0x64`.
Enable Developer Options and select Allow unsupported Macs in the GUI, or pass
`--developer` in the TUI/CLI. This enables only compiled experimental profiles;
an unknown board still needs its own profile and firmware qualification.
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
declared in the board's profile file. CDN image metadata and bundled boot assets
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
OS choices come from the live CDN image metadata.

## Legal

Licensed under the GPL 2.0. This is a from scratch rewrite, but the existing
Python/CLI based Asahi installer under the MIT license was used as a reference.
Upstream attribution is retained in the existing [LICENSE](LICENSE) file and
included in the app's copy of that file.

Artwork, the bootloader submodule, and embedded design fonts retain their own
licenses.

## Defining an OS release

Publish an entry in `os_list` in
[GravityLinux/installer-data](https://github.com/GravityLinux/installer-data),
then publish that JSON to `/installer/installer_data.json` on the CDN. GitHub
changes alone do not publish CDN objects. The existing format includes `name`,
`package`, `boot_object`, `next_object`, `supported_fw`, `partitions` and optional
`expert`. Set `install_mode` to `linux`, `uefi` or `bootloader` (omitting it means
`linux`). Relative packages resolve under the repository's `/os/`; absolute
HTTPS package URLs are also supported.

New images should set `supported_boards` to product numbers such as `["j700"]`,
or use `supported_devices` for exact device classes. All supplied selectors and
firmware constraints must match. Existing unscoped metadata is accepted only by
the original j773g profile, via its `acceptsUnscopedImages` compatibility setting.
It is never assumed compatible with j700 or another newly added board.

The installer validates image layouts before Review. Candidate IDs cover the
complete metadata and repository URL, so a changed image or layout requires a
new review when the privileged process checks the CDN again. Maintenance and
offline 1TR finalization do not depend on a live image listing. The generic
Bootloader only choice uses the bundled stage-1 binary and leaves the remaining
selected space free.
