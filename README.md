# Swiftpoint Creator macros

Task View and Undo scaffold frontend frameworks. The screenshot button also records. Both
capture paths go through the Windows Snipping Tool.

Each button sends one fixed chord and nothing else. An AutoHotkey v2 relay reads the chord,
resolves tap / double-tap / hold, and acts. The mouse is programmed once; everything after
that changes in this repo.

Deep Click is not used. The Creator has pressure sensors on Left Click and Left Fingertip
only, and none of these three buttons is either.

## Bindings

| Button | Gesture | Action |
|---|---|---|
| Task View | tap | Scaffold Vite + React + TypeScript |
| Task View | double tap | Scaffold Next.js |
| Undo | tap | Scaffold SvelteKit |
| Undo | double tap | Scaffold Astro |
| Screenshot | tap | Full-screen screenshot (`Win+Shift+S`) |
| Screenshot | hold ≥400ms | Start/stop recording (`Win+Shift+R`) |

Chords are `Ctrl+Alt+Shift+F13` / `F14` / `F15`. F13–F15 have no physical key, so nothing
else on the system can collide with them.

## Setup

```powershell
pwsh -File tools/install.ps1
```

Installs AutoHotkey v2, generates the derived files, registers the relay to start at login,
launches it. Then:

1. Program the three chords — [docs/control-panel-entry-sheet.md](docs/control-panel-entry-sheet.md).
2. Press `Win+Shift+S` and set the mode to **Full screen**. The overlay keeps the last-used
   mode, which is why the screenshot macro is a single keystroke with no menu navigation.
3. `pwsh -File tools/verify.ps1 -Test`

## Adding scaffold code

The four scripts in [scaffolds/](scaffolds/) are stubs: they log to `logs/scaffold.log` and
show a toast. Replace the `Invoke-ScaffoldStub` call with real code — only that file changes.

Projects are created under `~/Projects`; override with `SWIFTPOINT_SCAFFOLD_ROOT`.

## Changing bindings

[config/bindings.json](config/bindings.json) holds the chords, gesture modes, slot names and
timings. After editing:

```powershell
pwsh -File tools/generate.ps1
```

This regenerates `relay/bindings.generated.ahk` and `docs/control-panel-entry-sheet.md`.
`verify.ps1` fails if they drift out of sync with the config.

## Checks

```powershell
pwsh -File tools/ci.ps1
```

The same script CI runs: JSON parses, PowerShell parses, sources are ASCII-only,
PSScriptAnalyzer, the committed generated files match a fresh `generate.ps1` run and contain
no absolute paths or BOM, the relay compiles under AutoHotkey `/validate`, the relay starts
and registers the expected chord count, every scaffold stub exits 0, and every relative
markdown link resolves.

Scripts stay ASCII-only on purpose. Windows PowerShell 5.1 reads BOM-less files as ANSI, so a
single non-ASCII character in a string literal breaks parsing — and the relay falls back to
5.1 when PowerShell 7 is absent.

Generation is machine-independent: paths in `relay/bindings.generated.ahk` are repo-relative
and the relay resolves them against its own location, and the config hash ignores line-ending
style. A checkout on any machine regenerates byte-identical files.

The runtime check restarts the relay. One that was already running is put back in normal mode
afterwards.

CI runs on `windows-latest` for every push and pull request. Tagging `v*` runs the same
checks and, if they pass, publishes a bundle built by `tools/pack.ps1`.

## Layout

| Path | |
|---|---|
| `config/bindings.json` | Source of truth |
| `relay/swiftpoint-relay.ahk` | Gesture resolution, Snipping Tool sequences |
| `relay/bindings.generated.ahk` | Generated |
| `scaffolds/` | Slot scripts and shared helpers |
| `tools/generate.ps1` | Regenerates derived files |
| `tools/install.ps1` | Setup |
| `tools/verify.ps1` | Checks, and test mode |
| `tools/emit-spcf.ps1` | Reads an exported `.spcf`, documents its structure |
| `docs/control-panel-entry-sheet.md` | Generated: what to click in the Control Panel |
| `reference/` | Exported `.spcf` goes here |

## Troubleshooting

`pwsh -File tools/verify.ps1 -Test` restarts the relay so every gesture shows a tooltip
instead of acting.

| Symptom | Cause |
|---|---|
| Tooltip from keyboard, not from mouse | The Control Panel isn't emitting the chord. Its keyboard recorder can't capture F13–F15, so pick them from the key list. If F13–F24 aren't offered, set `activeChordSet` to `"f9"` and regenerate. |
| Two tooltips from one gesture | `timing.doubleTapMs` too short. |
| Hold never triggers | Chord isn't staying down. Turn off Auto-Release Outputs for that mapping, or set the button's `mode` to `"tapDouble"` and regenerate. |
| Screenshot captures a region | Overlay's last-used mode isn't Full screen. Set it once, or set `snip.forceMode` to `true`. |
| `Win+Shift+R` does nothing | Needs Windows 11 build 22621+. |

## Direct import (.spcf)

`.spcf` is text-editable but has no published schema, so a hand-written profile can corrupt
the profiles already on the mouse. Export one from the Control Panel into `reference/` and
run `pwsh -File tools/emit-spcf.ps1`. It reads the export without modifying it and writes
`docs/spcf-schema.md`, which the merge step is built against. Keep an unedited backup.
