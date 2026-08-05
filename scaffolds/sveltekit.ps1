# Slot: SvelteKit.  Fired by Undo, single tap.
# Stub. Replace the Invoke-ScaffoldStub call below.

. "$PSScriptRoot/_common.ps1"

Invoke-ScaffoldStub -Slot 'sveltekit' -Description 'SvelteKit'

# Real code goes here; delete the call above. Only this file changes.
#
#     $target = New-ScaffoldTargetPath -Slot 'sveltekit'
#     Write-ScaffoldLog "Scaffolding into $target"
#
#     npx sv create $target --template minimal --types ts --no-add-ons
#     Push-Location $target
#     npm install
#     Pop-Location
#
#     Show-ScaffoldToast -Title 'SvelteKit ready' -Message $target
#     code $target
