# Swiftpoint Creator macros

Four profiles cover every programmable button on the Creator: **Working** everywhere,
**Gaming** for Minecraft and Manor Lords, and **Contest Management** in the browser kept for
contest work. The Control Panel switches between them by the focused app.

Most buttons are programmed natively in the Control Panel: clicks, Back/Forward, copy and
paste, game keys, held Shift and Ctrl. They act with no latency and never touch this repo's
code. The rest emit one key each from F13-F23, and an AutoHotkey v2 relay maps that key to
something a mouse cannot do by itself: a screenshot saved as a file, launching an app,
opening a link, a calibrated 180 degree turn, or a scroll layer. Each relay key is unique
across all profiles, so the relay does not need to know which profile is active.

## Bindings

**Bold** buttons go through the relay; the rest are native.

| Button | Working | Gaming (Minecraft) | Gaming (Manor Lords) | Contest Management |
|---|---|---|---|---|
| Left click | Left Click | Left Click | Left Click | Left Click |
| Right click | Right Click | Right Click | Right Click | Right Click |
| Left fingertip | Copy | Copy | Copy | **QuantEx / Bachelier Terminal Admin** |
| Right fingertip | Paste | Paste | Paste | **Critical Debug Output** |
| Front edge | Redo | Pause / Game Menu (`Esc`) | Roads (`R`) | Copy |
| Rear edge | Undo | Inventory (`E`) | Construction (`C`) | Paste |
| Top thumb | Forwards | Sneak (hold `Left Shift`) | Pause / Resume (`Space`) | **Main Staff Discord** |
| Bottom thumb | Backwards | **180 degree turn** | Region Map (`M`) | **Live Leaderboard** |
| Middle button | Middle Click | Pick Block | Pick Block | Middle Click |
| Scroll | Scroll | Hotbar | Hotbar | Scroll |
| Left trigger push | **Screenshot (.jpg)** | Sprint (hold `Left Ctrl`) | Increase Speed (`X`) | **Navigation layer** |
| Left trigger pull | **Open VS Code** | Toggle Perspective (`F5`) | Decrease Speed (`Z`) | Previous tab (`Ctrl+Shift+Tab`) |
| Right trigger push | **Open File Explorer** | Swap Offhand (`F`) | Jump to Town (`T`) | **Debug layer** |
| Right trigger pull | **Open GitHub** | Debug Screen (`F3`) | More UI Info (`Tab`) | Next tab (`Ctrl+Tab`) |

### Scroll layers

While a Contest Management trigger is pushed, the wheel no longer scrolls. Each direction
opens a link instead, at most once per push:

| Trigger held | Scroll left | Scroll right | Scroll forward | Scroll back |
|---|---|---|---|---|
| Left (Navigation) | Organisers Discord | Technical Team Discord | Code Court Judge Dashboard | Contestant Portal |
| Right (Debug) | Judge / Submission Logs | Trading Engine Logs | Service Health / Metrics | Leaderboard Administration |

Releasing the trigger produces no output. The scroll layers of every other trigger push
are unassigned, so there the wheel scrolls as normal.

### Screenshot

The screenshot is saved as a `.jpg` in `Pictures\Screenshots` and also put on the clipboard.
It does not go through the Snipping Tool: its overlay opens in whatever mode was last used
and ignores injected keystrokes, so no macro can force a full-screen capture through it. The
relay grabs the virtual screen directly instead, which needs no setup. It covers every monitor
at its full physical resolution. The capture is DPI-aware, since a scaled display would
otherwise yield only its top-left corner.

The JPEG is written at the GDI+ default quality. An explicit quality setting would
need the codec-parameter API, and that API next to a screen grab is blocked by Defender as
malicious, so the script would not even run.

## Setup

```powershell
pwsh -File tools/install.ps1
```

Installs AutoHotkey v2, generates the derived files, registers the relay to start at login,
launches it. Then:

1. Program the four profiles: [docs/control-panel-entry-sheet.md](docs/control-panel-entry-sheet.md).
2. Optionally, the real contest URLs (below).
3. `pwsh -File tools/verify.ps1 -Test`

## Contest links

The repository is public, so [config/bindings.json](config/bindings.json) holds placeholder
URLs only. The real ones go in `config/links.local.json`, which is gitignored:

1. Copy [config/links.local.example.json](config/links.local.example.json) to
   `config/links.local.json`.
2. Replace each placeholder. A key left out falls back to its placeholder, and the relay logs
   a warning once.
3. Optionally set `browser` to the full path of the browser linked to Contest Management. A
   link opened in a different browser moves focus there and switches the profile off.

The relay re-reads the file on its next use. It is guaranteed that the file never reaches a
generated file, the log, or a release bundle: the generator never reads it, the relay logs only
whether a link was `local` or `placeholder`, `tools/pack.ps1` strips it, and CI fails if the
ignore rule is removed.

## 180 degree turn

The turn moves the mouse by `turn.counts` relative counts, which is exact at Minecraft's
default sensitivity. A different sensitivity needs recalibrating; the steps are in the [entry sheet](docs/control-panel-entry-sheet.md#calibrating-the-180-degree-turn).

## Changing bindings

[config/bindings.json](config/bindings.json) holds the profiles, the relay actions, the keys
and the timings. After editing:

```powershell
pwsh -File tools/generate.ps1
```

This regenerates `relay/bindings.generated.ahk`, `docs/control-panel-entry-sheet.md` and
`config/links.local.example.json`. The relay reads its bindings only when it starts, so reload
it afterwards: tray icon > **Reload**. Every profile must define all fifteen buttons, each
either `native` or `relay`, and every action must be reached by some button or layer; the
generator refuses anything else. `verify.ps1` fails if the generated files
drift out of sync with the config.

## Checks

```powershell
pwsh -File tools/ci.ps1
```

The same script CI runs. It checks that:

- the JSON parses, and `config/links.local.json` is gitignored and does not leak into a
  generated file;
- the PowerShell parses, sources are ASCII-only, the module manifest exports exactly the
  public functions, and PSScriptAnalyzer (formatting rules included) reports nothing;
- the committed generated files match a fresh `generate.ps1` run and contain no absolute
  path or BOM;
- the relay and the module share one URL rule, and the relay and the selftest compile under
  AutoHotkey `/validate`;
- the relay starts and registers the expected key count;
- the relay behaves: [tools/relay-selftest.ahk](tools/relay-selftest.ahk) presses every key
  with auto-repeats, once more under a held Ctrl, and holds each layer trigger through
  repeated wheel events in every direction, and pushes one layer trigger over the other. The
  relay's log must match the selftest line for line;
- the screenshot is a real `.jpg` of the full virtual screen;
- every relative markdown link resolves.

Scripts stay ASCII-only on purpose. Windows PowerShell 5.1 reads BOM-less files as ANSI, so a
single non-ASCII character in a string literal breaks parsing, and the relay falls back to
5.1 when PowerShell 7 is absent.

Generation is machine-independent: paths in `relay/bindings.generated.ahk` are repo-relative
or `%VAR%`, the relay resolves them at runtime, and the config hash ignores line-ending style.
A checkout on any machine regenerates byte-identical files.

The runtime checks restart the relay in test mode. A relay that was already running is put
back in normal mode afterwards, even if the run fails partway.

CI runs on `windows-latest` for every push and pull request. Tagging `v*` runs the same
checks and, if they pass, publishes a bundle built by `tools/pack.ps1`.

## Layout

| Path | |
|---|---|
| `config/bindings.json` | Source of truth |
| `config/links.local.example.json` | Generated: template for the real contest URLs |
| `config/links.local.json` | Gitignored: the real contest URLs |
| `relay/swiftpoint-relay.ahk` | Relay entry point: includes `relay/lib/` and starts up |
| `relay/lib/` | Relay code: hotkeys, scroll layers, actions, links, logging, tray |
| `relay/bindings.generated.ahk` | Generated |
| `capture/capture-fullscreen.ps1` | Full-screen capture to `.jpg` and clipboard |
| `tools/SwiftpointConfig/` | PowerShell module shared by every script in `tools/` |
| `tools/generate.ps1` | Validates the config, regenerates derived files |
| `tools/install.ps1` | Setup |
| `tools/verify.ps1` | Checks, and test mode |
| `tools/relay-selftest.ahk` | Drives the relay synthetically for the checks |
| `tools/emit-spcf.ps1` | Reads an exported `.spcf`, documents its structure |
| `docs/control-panel-entry-sheet.md` | Generated: what to click in the Control Panel |
| `reference/` | Exported `.spcf` goes here |
| `.editorconfig`, `.gitattributes` | Encoding, indentation and CRLF line endings |

## Code style

The scripts in `tools/` are thin: config loading, validation, rendering, relay control and the
check reporting all live in the `SwiftpointConfig` module, whose manifest lists its public
functions. [PSScriptAnalyzerSettings.psd1](PSScriptAnalyzerSettings.psd1) enforces brace
placement, indentation, whitespace and Windows PowerShell 5.1 compatible syntax, and CI fails
on any finding. `Invoke-Formatter -Settings PSScriptAnalyzerSettings.psd1` fixes most of them.

## Troubleshooting

`pwsh -File tools/verify.ps1 -Test` restarts the relay in test mode and runs the selftest, so
every relay button shows a tooltip instead of acting. Native buttons act as normal.

| Symptom | Cause |
|---|---|
| Selftest tooltips appear, but none from the mouse | The Control Panel isn't emitting the key. Its keyboard recorder can't capture F13-F24, so pick them from the key list. If they aren't offered, set `activeChordSet` to `"ctrlAltShift"`, regenerate, reload the relay and reprogram. Tray icon > **Key history** in test mode shows what arrived. |
| The page scrolls while a Contest trigger is pushed | Auto-Release Outputs is on for that trigger. Turn it off. |
| The wheel stops scrolling everywhere | A layer trigger's release was lost. The relay leaves the layer by itself after `timing.layerTimeoutMs`, and logs it. |
| A contest button opens a placeholder (a `.example` page, or a Discord link with `_ID` in it) | Its key is missing from `config/links.local.json`, or still holds the value copied from the example. `verify.ps1` names which. |
| The turn overshoots or falls short | Minecraft's sensitivity changed, or Raw Input is off. Recalibrate `turn.counts`. |
| A native button acts in the wrong profile | The sub-profile isn't linked to the focused app, or the Control Panel isn't running to switch it. |
| Screenshot does nothing | Check `logs/capture.log`. The capture runs as a PowerShell script, so a blocked interpreter or a locked clipboard shows up there. |

## Direct import (.spcf)

`.spcf` is text-editable but has no published schema, so a hand-written profile can corrupt
the profiles already on the mouse. Export one from the Control Panel into `reference/` and
run `pwsh -File tools/emit-spcf.ps1`. It reads the export without modifying it and writes
`docs/spcf-schema.md`, which the merge step is built against. Keep an unedited backup.
