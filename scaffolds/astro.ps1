# Slot: Astro.  Fired by Undo, double tap.
# Stub. Replace the Invoke-ScaffoldStub call below.

. "$PSScriptRoot/_common.ps1"

Invoke-ScaffoldStub -Slot 'astro' -Description 'Astro'

# Real code goes here; delete the call above. Only this file changes.
#
#     $target = New-ScaffoldTargetPath -Slot 'astro'
#     Write-ScaffoldLog "Scaffolding into $target"
#
#     npm create astro@latest $target -- --template minimal --typescript strict --install --no-git --yes
#
#     Show-ScaffoldToast -Title 'Astro ready' -Message $target
#     code $target
