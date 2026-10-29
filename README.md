# Gravity Linux installer

WIP: Experimental Gravity Linux installer

This will become the default installer of the Gravity Linux project.

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

The Neo collector packages MT7932 firmware, the MT793B B1 upload payload and
IMX558 camera setfile. It archives factory BWC2 data, AID44 audio tuning and
selected restore firmware for later rebuilds. Resident AOP/PMP/ISP/DCP/GPU
firmware is supplied by the selected restore and iBoot, not uploaded by the
installer firmware package.

The current Linux Wi-Fi ABI also requires two per-radio calibration caches.
Provide a directory containing `mediatek/mt7932/calibration-<MAC>.bin` and
`mediatek/mt7932/precal-<MAC>.bin`. These must be the target radio’s captures:
the collector checks the factory MAC, file formats and RF payloads against
that machine’s fresh BWC2 record. It does not regenerate these caches solely
from factory data yet and never substitutes another machine’s calibration.
Normal installation expects them under `Contents/Resources/board-calibration/j700`.

The packaged executable can qualify collection without installing:

```sh
"Gravity Installer.app/Contents/MacOS/gravity-installer" \
  --developer \
  --handoff-bundle "$HOME/neo-handoff" \
  --calibration-cache "$HOME/neo-calibration"
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
