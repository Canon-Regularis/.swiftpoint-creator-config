# Slot: Vite + React + TypeScript.  Fired by Task View, single tap.
# Stub. Replace the Invoke-ScaffoldStub call below.

. "$PSScriptRoot/_common.ps1"

Invoke-ScaffoldStub -Slot 'vite-react-ts' -Description 'Vite + React + TypeScript'

# Real code goes here; delete the call above. Only this file changes.
#
#     $target = New-ScaffoldTargetPath -Slot 'vite-react-ts'
#     Write-ScaffoldLog "Scaffolding into $target"
#
#     npm create vite@latest $target -- --template react-ts
#     Push-Location $target
#     npm install
#     Pop-Location
#
#     Show-ScaffoldToast -Title 'Vite + React + TS ready' -Message $target
#     code $target
