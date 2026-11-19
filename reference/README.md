# reference/

Exported Swiftpoint profiles go here as `*.spcf`, then:

```powershell
pwsh -File tools/emit-spcf.ps1
```

It writes `docs/spcf-schema.md`. It is guaranteed that the export itself is only read, never
modified.

To export: Control Panel, **Expert Mode** (bottom left), export profiles to a `.spcf`.

Keep an unedited backup. `.spcf` has no published schema, and a malformed import can destroy
the profiles already on the mouse.

`.spcf` files are gitignored: they are personal device config.
