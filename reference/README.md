# reference/

Exported Swiftpoint profiles go here as `*.spcf`, then:

```powershell
pwsh -File tools/emit-spcf.ps1
```

It reads the export without modifying it and writes `docs/spcf-schema.md`.

To export: Control Panel, **Expert Mode** (bottom left), export profiles to a `.spcf`.

Keep an unedited backup. `.spcf` has no published schema, and a malformed import can destroy
the profiles already on the mouse.

`.spcf` files are gitignored.
