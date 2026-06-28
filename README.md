<!-- GitHub topics: bluetooth ble bluetooth-low-energy corebluetooth swift macos tui cli
     scanner device-discovery ibeacon eddystone rssi beacon terminal apple-silicon
     fingerprinting gatt bluetooth-scanner -->

# blescan

[![CI](https://github.com/lucasdaddiego/blescan/actions/workflows/ci.yml/badge.svg)](https://github.com/lucasdaddiego/blescan/actions/workflows/ci.yml)
![platform](https://img.shields.io/badge/platform-macOS%2012%2B-black?logo=apple)
![language](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)
![dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
![license](https://img.shields.io/badge/license-MIT-blue)

A live terminal scanner that finds and **fingerprints every Bluetooth Low Energy device
around you** — vendor, device‑type guess, advertised services, and a live signal trace —
straight off **CoreBluetooth**. The Bluetooth sibling to my LAN scanner
([lanscan](https://github.com/lucasdaddiego/lanscan)) and Wi‑Fi scanner
([macos‑wifi‑scan](https://github.com/lucasdaddiego/macos-wifi-scan)), completing the
"scan everything around you" trilogy.

A single self‑contained Swift binary. No Homebrew, no Python, no `pip`, no third‑party
packages, no root.

<!-- Demo: record with `asciinema rec`, then drop the cast id in below. -->
[![asciicast](https://asciinema.org/a/PLACEHOLDER.svg)](https://asciinema.org/a/PLACEHOLDER)

```
  blescan   adapter poweredOn   permission authorized   ⠹ scanning…
 devices 14  shown 14   sort RSSI↓   conn-only off   named-only off   last 19:44
 ──────────────────────────────────────────────────────────────────────────────────────────────────────
 Name              Vendor           Type                 dBm  Signal     Prox       Conn  Age   Trend
 Lucas’ AirPods    Apple            AirPods / Apple aud. -41  ████████·  immediate  yes     1s  ▅▆▆▇█▇▆▇
 living-room       Apple            Find My / AirTag     -52  ██████··   near        no     0s  ▄▄▅▄▅▅▄▅
 Polar H10         Polar            Heart-rate monitor   -58  █████···   near       yes     2s  ▃▄▃▄▄▃▄▄
 RuuviTag EA3F     Ruuvi Innov.     Environmental sensor -66  ████····   near        no     1s  ▃▃▂▃▃▃▂▃
 Tile             0x0157            Tile tracker         -71  ███·····   near       yes     3s  ▂▂▃▂▂▂▂▂
 Kitchen Beacon    Apple            iBeacon              -74  ███·····   far         no     0s  ▂▂▁▂▂▂▁▂
 (unnamed)         Samsung Elec.    BLE device           -80  ██······   far         no     4s  ▁▂▁▁▂▁▁▁
 (unnamed)         —                —                    -89  █·······   far         ?      6s  ▁▁▁▁▁▁▁▁
 ──────────────────────────────────────────────────────────────────────────────────────────────────────
 ▎ Polar H10
 identifier   B6F5…-…-…-…-9A21   (host-stable UUID, not a MAC)
 signal       -58 dBm  near   conn yes   tx -4 dBm   seen 2s ago
 vendor       Polar   type Heart-rate monitor
 services     Heart Rate (0x180D), Battery (0x180F), Device Information (0x180A)
 manufacturer 6 bytes
   0000  d1 00 01 02 00 03                                 |......|
 ──────────────────────────────────────────────────────────────────────────────────────────────────────
 [q]uit  [j/k]select  [p]ower [n]ame [v]endor [t]ype a[g]e sort  [c]onn-only [u]named-only  [/]filter
```

## Contents

- [Features](#features)
- [Why Swift + CoreBluetooth?](#why-swift--corebluetooth)
- [Requirements](#requirements)
- [Install](#install)
- [First run: grant Bluetooth permission](#first-run-grant-bluetooth-permission)
- [Usage](#usage)
- [Reading the table](#reading-the-table)
- [The detail pane](#the-detail-pane)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [How the fingerprinting works](#how-the-fingerprinting-works)
- [JSON output](#json-output)
- [Honesty notes & known limitations](#honesty-notes--known-limitations)
- [How the permission prompt works (no .app bundle)](#how-the-permission-prompt-works-no-app-bundle)
- [Architecture](#architecture)
- [Project layout](#project-layout)
- [Development](#development)
- [License](#license)

## Features

- **Live advertisement scan** — continuous discovery via `CBCentralManager` + the
  `didDiscover` delegate, one live‑updating row per device, with **`allowDuplicates`**
  on so RSSI updates in real time (see [limitations](#honesty-notes--known-limitations)).
- **Full advertisement read** — local name, manufacturer data, service UUIDs, service
  data, TX power, connectable flag, and the solicited / overflow service lists.
- **Vendor & device‑type fingerprinting** — the 2‑byte **company identifier** resolved
  against the Bluetooth SIG company list (Apple, Samsung, Google, Nordic, …), plus
  recognition of **iBeacon**, **Eddystone** (UID/URL/TLM/EID), **Tile**, **AirPods /
  Apple Continuity**, **Find My**, **heart‑rate & fitness** services, HID, mesh and more.
- **Resolved services** — well‑known SIG service UUIDs shown by friendly name
  (`Heart Rate (0x180D)`), not raw hex.
- **Live signal** — colour‑coded RSSI and signal bar, a **per‑device sparkline** of the
  recent trend, and an **RSSI → proximity** estimate (immediate / near / far) using the
  advertised calibration when present.
- **Sortable / filterable** — sort by RSSI, name, vendor, type or age (reverse with the
  same key); live substring **filter**; **connectable‑only** and **named‑only** toggles.
- **Detail pane** — full per‑device breakdown including a **hex dump of the raw
  advertisement bytes** (manufacturer + each service‑data entry).
- **Modern‑terminal niceties** — flicker‑free **synchronized** frames, **mouse**
  (wheel selects, click a header to sort, click a row to inspect), a **24‑bit colour**
  gradient on truecolor terminals (256‑palette fallback), and a live window/tab title.
  All auto‑gated, so dumb terminals and pipes still work.
- **Scriptable** — `--once`, `--json` (pipe into `jq`) and `--diag` modes.
- **Single self‑contained binary**, code‑signed with the Info.plist embedded in the
  Mach‑O; **zero dependencies**, no root.

## Why Swift + CoreBluetooth?

On macOS, **BLE is reachable only through CoreBluetooth** (`CBCentralManager`). There is
no raw HCI socket as on Linux, so the BlueZ‑style tooling simply doesn't exist here. And
crucially for a *fingerprinting* tool, native Swift is the only path that hands back the
**full, unflattened `advertisementData` dict** — every cross‑language wrapper (Rust
`btleplug`, Python `bleak`) drops or flattens advertisement detail on macOS, which would
disqualify it. So `blescan` talks to CoreBluetooth directly in Swift and hand‑rolls the
TUI — nothing to install, and nothing between you and the raw advert bytes.

## Requirements

- **macOS** (built & tested on **macOS 26 / Apple Silicon**; targets macOS 12+).
- **Xcode Command Line Tools** for `swiftc` — `xcode-select --install`.
- A Bluetooth radio that's turned on. That's it — no Homebrew formulae, no Swift packages.

> **Linux / Windows:** **N/A.** CoreBluetooth is macOS‑only; a Linux port would be an
> entirely different program built on BlueZ/HCI (a different stack, different data, no
> shared code), so it's out of scope here rather than "planned".

## Install

```sh
make install    # build + sign the optimised `blescan` binary into ~/.bin
make uninstall  # remove it
```

`make install` compiles an optimised, fully‑stripped binary (no debug info), **embeds the
`Info.plist`** into the Mach‑O (so a bundle‑less CLI can still request Bluetooth — see
[below](#how-the-permission-prompt-works-no-app-bundle)), ad‑hoc code‑signs it, and drops
a **`blescan`** command into **`~/.bin`**.

Make sure `~/.bin` is on your `PATH`:

```sh
echo 'export PATH="$HOME/.bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

## First run: grant Bluetooth permission

macOS gates BLE scanning behind a **Bluetooth** privacy permission. On first run macOS
prompts; click **Allow**. If you miss it:

1. Run `blescan` (or `blescan --diag`) once.
2. **System Settings → Privacy & Security → Bluetooth** → enable **blescan**.
3. Run `blescan` again. `blescan --diag` should report **`adapter state: poweredOn`**.

### Keep the grant across rebuilds (optional)

Ad‑hoc signing gives the binary a new identity on every `make install`, so macOS forgets the
grant and re‑prompts. To make it **stick across rebuilds**, sign with a stable
self‑signed certificate:

1. **Keychain Access → Certificate Assistant → Create a Certificate…**
   — Name e.g. `blescan-codesign`, Identity Type **Self Signed Root**, Certificate Type
   **Code Signing**.
2. Create a git‑ignored `Makefile.local`:
   ```make
   SIGN := blescan-codesign
   ```
3. `make install` now signs with that identity. Grant Bluetooth once; every future build keeps it.

(The public repo defaults to ad‑hoc signing, so `make install` works for everyone with no setup.)

## Usage

```sh
blescan                  # interactive TUI (default)
blescan --once           # scan ~6s, print the device table, then exit
blescan --json           # scan ~6s, emit the devices as JSON on stdout (pipe into jq)
blescan --diag           # adapter + permission diagnostics
blescan --help           # usage summary
```

| Flag | Description |
|------|-------------|
| `--once` | Single ~6 s scan; print the device table, then exit. |
| `--json` | Single ~6 s scan; emit a JSON array on stdout. |
| `--diag` | Print adapter state, permission status and device/name counts. |
| `--help`, `-h` | Show usage. |

Everything else is a **live** TUI control (see [shortcuts](#keyboard-shortcuts)).
**Colour is automatic:** on in a terminal, off when piped or redirected. Set `NO_COLOR`
to force it off. **Truecolor** is used when the terminal advertises it
(`COLORTERM=truecolor`, as Ghostty/iTerm/kitty do); otherwise the 256‑colour palette.

## Reading the table

| Column | Meaning |
|--------|---------|
| **Name** | Advertised local name (or the cached GAP name). `(unnamed)` if the device advertises none. |
| **Vendor** | Manufacturer, from the 2‑byte company identifier in manufacturer data. An unknown id is shown honestly as `0xXXXX`; `—` means no manufacturer data at all. |
| **Type** | Best‑guess device category from services + manufacturer signature (see [fingerprinting](#how-the-fingerprinting-works)). |
| **dBm** | RSSI / signal power. Closer to 0 is stronger (`-41` ≫ `-89`). `—` if unavailable. |
| **Signal** | Colour bar of the same value. |
| **Prox** | Proximity estimate: **immediate / near / far**, or `—` when not estimable. |
| **Conn** | Whether the device advertises as connectable: `yes` / `no` / `?`. |
| **Age** | Time since the last advertisement was heard. Rows fade as they go stale and are dropped after 60 s of silence. |
| **Trend** | Sparkline of recent RSSI (last ~24 samples, ~1/s), so you can watch a device approach or recede. Wide terminals only. |

**Signal colour key** (by dBm): bright‑green `≥ -55` · green `-55…-67` · yellow
`-67…-77` · orange `-77…-87` · red `< -87`. On truecolor terminals this is a smooth
gradient rather than five steps.

## The detail pane

The bottom pane expands the **selected** device (move the selection with `j`/`k`, the
arrows, the mouse wheel, or by clicking a row). It shows the host‑stable identifier, the
full signal line (RSSI, proximity, estimated distance when a calibration is present, TX
power, connectable, age), vendor and type, the **resolved service list**, any decoded
**iBeacon / Eddystone / Continuity** payloads, and a **hex dump of the raw manufacturer
and service‑data bytes** — the advertisement exactly as it came off the air.

## Keyboard shortcuts

| Key | Action | | Key | Action |
|-----|--------|-|-----|--------|
| `q` / `Ctrl‑C` / `Ctrl‑D` | quit | | `p` | sort by **p**ower (RSSI) |
| `j` / `k` / `↓` / `↑` | move selection | | `n` | sort by **n**ame |
| `c` | **c**onnectable‑only toggle | | `v` | sort by **v**endor |
| `u` | named‑only toggle | | `t` | sort by **t**ype |
| `/` | **filter** (Enter apply, Esc clear) | | `g` | sort by a**g**e |
| | | | | press a sort key again to reverse |

### Mouse

On terminals with mouse reporting (Ghostty, iTerm, kitty, Terminal.app …):

- **Scroll wheel** — move the selection up / down.
- **Click a row** — select it (its details fill the pane).
- **Click a column header** — sort by that column (click again to reverse).

Mouse reporting takes over click‑drag, so to **select/copy** text hold **Shift** while
dragging (the standard terminal bypass).

## How the fingerprinting works

Because macOS gives no MAC/OUI (see [limitations](#honesty-notes--known-limitations)),
identity is built entirely from the **advertisement** itself:

1. **Company identifier.** The first two bytes of manufacturer data are a little‑endian
   **Bluetooth SIG company id**, resolved against a curated subset of the SIG registry
   (Apple `0x004C`, Samsung `0x0075`, Google `0x00E0`, Nordic `0x0059`, …). Unknown ids
   are shown as `0xXXXX` — never guessed.
2. **iBeacon.** Apple's `4C 00 02 15 …` layout is decoded to its proximity **UUID /
   major / minor / measured‑power**.
3. **Eddystone** (Google's open beacon format, in the `0xFEAA` service data) — **UID**
   (namespace/instance), **URL** (expanded from its compressed form), **TLM** (battery,
   temperature, advertising count, uptime) and **EID**.
4. **Apple Continuity.** The TLV segment stream is walked to recognise **AirPods /
   Proximity Pairing**, **Handoff**, **Nearby**, **Find My**, AirDrop, and friends.
5. **Service UUIDs.** Well‑known SIG services map both to friendly names and to a
   **device‑type guess** — Heart Rate → *heart‑rate monitor*, HID → *keyboard/mouse*,
   Cycling Power / Fitness Machine → *fitness sensor*, Environmental Sensing → *sensor*,
   Mesh Provisioning/Proxy → *mesh node*, Tile / Exposure Notification / Fast Pair, etc.
6. **Proximity.** When the advertisement carries a calibrated reference (the iBeacon 1 m
   measured power, or an Eddystone TX power), `blescan` runs the standard path‑loss curve
   to bucket distance; otherwise it falls back to RSSI thresholds. It's a **rough
   estimate**, not a measurement — radio environment dominates.

All of this lives in the framework‑free `Core.swift`, unit‑tested at **100% coverage**.

## JSON output

`blescan --json` scans for a few seconds and prints a pretty array (sorted by RSSI,
strongest first; keys alphabetised). Fields that aren't advertised are omitted — beacons
add structured `iBeacon` / `eddystone` fields, `serviceData` carries the raw hex of each
service‑data entry, `companyId` is the raw `0xXXXX`, and `rssi` is dropped when the radio
reports it unavailable:

```jsonc
[
  {
    "companyId": "0x004C",
    "connectable": true,
    "continuity": ["AirPods / Proximity Pairing"],
    "id": "B6F5B1C0-1A2B-3C4D-5E6F-9A21C5D4E3F2",
    "manufacturerHex": "4c000719...",
    "name": "Lucas’ AirPods",
    "proximity": "immediate",
    "rssi": -41,
    "services": ["Battery (0x180F)"],
    "txPower": 12,
    "type": "AirPods / Apple audio",
    "vendor": "Apple"
  }
]
```

Example — list every Apple device strongest‑first:

```sh
blescan --json | jq -r '.[] | select(.vendor=="Apple") | "\(.rssi)\t\(.name // "(unnamed)")\t\(.type)"'
```

## Honesty notes & known limitations

- **No MAC address — and so no OUI lookup.** macOS privacy‑randomises BLE addresses and
  never exposes them to a third party; CoreBluetooth hands back a host‑stable
  `CBPeripheral.identifier` **UUID** instead (it differs across machines and can rotate).
  So unlike [lanscan](https://github.com/lucasdaddiego/lanscan) — which keys vendor off
  the MAC's **OUI** — `blescan` gets vendor purely from the **manufacturer‑data company
  id** and **service UUIDs**. A device that advertises neither shows `—`.
- **`allowDuplicates` is required for a live signal.** CoreBluetooth otherwise coalesces a
  device to a single discovery and the RSSI never moves; `blescan` enables it so each
  advertisement is delivered. (It's slightly higher‑power, which is fine for a foreground
  scanner.)
- **Proximity / distance is an estimate.** Even with a calibrated reference, BLE ranging
  is dominated by the environment (bodies, walls, antenna orientation). Treat
  immediate/near/far as a hint, not a tape measure.
- **The SIG tables are a curated subset.** The company‑id and service‑UUID registries
  have thousands of entries; `blescan` embeds a high‑confidence subset of the common
  ones. A missing entry is shown honestly (a `0xXXXX` company id or a raw `0x…` UUID),
  never mislabelled.
- **Names and services come and go.** Different advertisement and scan‑response packets
  carry different fields, so `blescan` merges the richest view it has heard for a device
  rather than dropping detail when a sparse packet arrives.

## How the permission prompt works (no .app bundle)

Unlike Wi‑Fi SSIDs (which macOS reveals only to a real LaunchServices *app session*), BLE
scanning just needs the **Bluetooth TCC grant** — which any process can request **as long
as it carries an `Info.plist` with `NSBluetoothAlwaysUsageDescription`.** A bare CLI has
no bundle to hold that plist, so `blescan` embeds it directly into the Mach‑O at link
time:

```
swiftc … -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist …
codesign --sign - --identifier com.lucasdaddiego.blescan blescan
```

macOS reads the `__TEXT,__info_plist` section for the usage string and shows the prompt
under the binary's name — no `.app` wrapper, no Apple Developer account, no special
entitlement. (This is the BLE analogue of how
[macos‑wifi‑scan](https://github.com/lucasdaddiego/macos-wifi-scan) ships an Info.plist
for its **Location** requirement — different permission, same embed trick.) Because the
ad‑hoc signature changes every build, the grant resets on each `make install`; sign with a
[stable cert](#keep-the-grant-across-rebuilds-optional) to keep it.

## Architecture

```
             you ── type `blescan` in a terminal
              │
              ▼
   ┌────────────────────────┐   Device   ┌──────────────────────────────┐
   │  TUI (main thread)      │ ◀───────── │  Radio (CBCentralManager)     │
   │  raw-mode render · keys │  (locked   │  on a private serial queue    │
   │  sort · filter · detail │   ingest)  │  didDiscover → build Device   │
   └────────────────────────┘            └──────────────────────────────┘
        reads snapshots, redraws                 delivers each advertisement
        when the generation advances             off the main thread
```

- **Radio** (`main.swift`): owns the `CBCentralManager` on a dedicated dispatch queue, so
  delegate callbacks land off the main thread. Each `didDiscover` is turned into a
  framework‑free `Device` and handed to the app under a lock. No out‑of‑process helper is
  needed (BLE has no SSID‑redaction quirk to work around).
- **App** (`main.swift`): the live device table, history ring buffers, UI state, and the
  raw‑mode ANSI renderer (master table + detail pane), painted with synchronized output
  and frame‑diffing so it never tears. It idles at near‑0% CPU when the radio is quiet; while
  actively scanning it does a light ~10 fps redraw to animate the spinner and signal trace.
- **Core** (`Core.swift`): all the pure logic — vendor/service/beacon fingerprinting, the
  proximity model, colour, sorting, hex dump and display‑width‑aware text layout —
  framework‑free and unit‑tested at 100%.

## Project layout

```
Sources/blescan/Core.swift   pure logic — fingerprinting · proximity · colour · sorting · layout
Sources/blescan/main.swift   CoreBluetooth (Radio) · TUI · entrypoint
Tests/CoreTests.swift        dependency-free unit tests for Core (`make test`, 100% covered)
scripts/check-coverage.sh    coverage gate — fails unless Core.swift is 100% region+line covered
.github/workflows/ci.yml     GitHub Actions: build + test + coverage gate on every push/PR
Info.plist                   Bluetooth usage string, embedded into the binary at link time
Makefile                     `make install` → signed blescan in ~/.bin; `make test` / `make coverage`
Package.swift                SwiftPM manifest (for editors/tooling/CI; the Makefile uses swiftc)
Makefile.local               optional, git-ignored: machine-local SIGN identity
```

No third‑party dependencies — just the system **CoreBluetooth** and **Foundation**
frameworks.

## Development

```sh
make                       # list targets (default; ≡ make help)
make install               # build + sign + install into ~/.bin
make build                 # build + sign ./blescan locally, no install (quick compile)
make run ARGS=--diag       # build, then run ./blescan with flags (≡ make diag)
make test                  # run the core unit tests (no Xcode/XCTest needed — CLT only)
make coverage              # run tests under llvm-cov; fails unless Core.swift is 100% covered
make clean                 # remove build artifacts (make uninstall removes ~/.bin/blescan)
```

Two files: **`Core.swift`** holds the pure, framework‑free logic (fingerprinting,
proximity, colour, sorting, hex dump, text layout, and terminal‑escape sanitization of
hostile device names) and is unit‑tested standalone via `make test`; **`main.swift`**
holds the `Radio` (CoreBluetooth wrapper) and the raw‑mode TUI.

`Core.swift` is held at **100% region + line coverage** — `make coverage` (and CI, on
every push/PR) re‑runs the tests under `llvm-cov` and `scripts/check-coverage.sh` fails
the build on any uncovered line. The split is deliberate: all branchy logic lives in
`Core.swift` so it's covered without the system frameworks, while `main.swift` is kept to
thin, framework‑bound plumbing.

## License

MIT — see [`LICENSE`](LICENSE). Copyright © 2026 Lucas Daddiego.
