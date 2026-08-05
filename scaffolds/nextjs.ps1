# Slot: Next.js.  Fired by Task View, double tap.
# Stub. Replace the Invoke-ScaffoldStub call below.

. "$PSScriptRoot/_common.ps1"

Invoke-ScaffoldStub -Slot 'nextjs' -Description 'Next.js'

# Real code goes here; delete the call above. Only this file changes.
#
#     $target = New-ScaffoldTargetPath -Slot 'nextjs'
#     Write-ScaffoldLog "Scaffolding into $target"
#
#     npx create-next-app@latest $target --typescript --tailwind --eslint --app --yes
#
#     Show-ScaffoldToast -Title 'Next.js ready' -Message $target
#     code $target
