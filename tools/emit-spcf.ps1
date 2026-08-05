<#
.SYNOPSIS
    Reads an exported Swiftpoint .spcf and writes docs/spcf-schema.md describing its structure.

.DESCRIPTION
    .spcf has no published schema. The source file is only read, never modified.
    -Merge is gated until the structure is confirmed: a malformed import can
    destroy the profiles already on the mouse.

.PARAMETER Source
    Path to an exported .spcf. Defaults to the newest one in reference/.

.PARAMETER Merge
    Write dist/creator-macros.spcf with the chord mappings merged in.

.EXAMPLE
    pwsh -File tools/emit-spcf.ps1
#>
[CmdletBinding()]
param(
    [string]$Source,
    [switch]$Merge
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot/_common.ps1"

$SchemaDoc = Get-RepoPath 'docs/spcf-schema.md'

# --- locate the export ------------------------------------------------------

if (-not $Source) {
    $referenceDir = Get-RepoPath 'reference'
    $found = Get-ChildItem -Path $referenceDir -Filter '*.spcf' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending |
             Select-Object -First 1
    if (-not $found) {
        Write-Host ''
        Write-Host 'No .spcf found.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  1. Control Panel, then Expert Mode (bottom left).'
        Write-Host '  2. Export your profiles to a .spcf.'
        Write-Host "  3. Save it in:  $referenceDir"
        Write-Host '  4. Re-run this script.'
        Write-Host ''
        Write-Host 'Keep an unedited backup of the export.' -ForegroundColor Yellow
        Write-Host ''
        exit 1
    }
    $Source = $found.FullName
}

if (-not (Test-Path -LiteralPath $Source)) {
    throw "Source not found: $Source"
}

$sourceItem = Get-Item -LiteralPath $Source
Write-Host ''
Write-Host "Inspecting: $($sourceItem.FullName)" -ForegroundColor Cyan
Write-Host ("Size: {0:N0} bytes    Modified: {1}" -f $sourceItem.Length, $sourceItem.LastWriteTime)
Write-Host ''

# --- detect the container ---------------------------------------------------

$bytes = [System.IO.File]::ReadAllBytes($sourceItem.FullName)
$magic = if ($bytes.Length -ge 4) { [System.BitConverter]::ToString($bytes[0..3]) } else { '' }

$text = $null
try {
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
} catch {
    $text = $null
}

$format = 'unknown'
$parsed = $null

if ($magic -like '50-4B-*') {
    $format = 'zip'                       # "PK.."
} elseif ($text -and $text.TrimStart() -match '^[\{\[]') {
    try {
        $parsed = $text | ConvertFrom-Json
        $format = 'json'
    } catch {
        $format = 'json-like (failed to parse)'
    }
} elseif ($text -and $text.TrimStart().StartsWith('<')) {
    try {
        $parsed = [xml]$text
        $format = 'xml'
    } catch {
        $format = 'xml-like (failed to parse)'
    }
} else {
    $format = 'binary'
}

Write-Host "Detected format: $format" -ForegroundColor Green
Write-Host ''

# --- outline ----------------------------------------------------------------

$outline = [System.Collections.Generic.List[string]]::new()

function Add-JsonOutline {
    param($Node, [string]$Path = '$', [int]$Depth = 0, [int]$MaxDepth = 7)

    if ($Depth -gt $MaxDepth) {
        $outline.Add("$Path  …(depth limit)")
        return
    }

    if ($null -eq $Node) {
        $outline.Add("$Path : null")
        return
    }

    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        $items = @($Node)
        $outline.Add("$Path : array[$($items.Count)]")
        if ($items.Count -gt 0) {
            Add-JsonOutline -Node $items[0] -Path "$Path[0]" -Depth ($Depth + 1) -MaxDepth $MaxDepth
        }
        return
    }

    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Node.PSObject.Properties) {
            Add-JsonOutline -Node $property.Value -Path "$Path.$($property.Name)" -Depth ($Depth + 1) -MaxDepth $MaxDepth
        }
        return
    }

    $sample = [string]$Node
    if ($sample.Length -gt 60) { $sample = $sample.Substring(0, 60) + '…' }
    $outline.Add("$Path : $($Node.GetType().Name) = $sample")
}

function Add-XmlOutline {
    param([System.Xml.XmlNode]$Node, [string]$Path = '', [int]$Depth = 0, [int]$MaxDepth = 7)

    if ($Depth -gt $MaxDepth) { return }

    foreach ($child in $Node.ChildNodes) {
        if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        $childPath = "$Path/$($child.Name)"
        $attributes = ''
        if ($child.Attributes -and $child.Attributes.Count -gt 0) {
            $attributes = ' [' + (($child.Attributes | ForEach-Object { $_.Name }) -join ', ') + ']'
        }
        $outline.Add("$childPath$attributes")
        Add-XmlOutline -Node $child -Path $childPath -Depth ($Depth + 1) -MaxDepth $MaxDepth
    }
}

switch -Wildcard ($format) {
    'json' { Add-JsonOutline -Node $parsed }
    'xml'  { Add-XmlOutline -Node $parsed }
    'zip'  {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($sourceItem.FullName)
        try {
            foreach ($entry in $archive.Entries) {
                $outline.Add(('{0}  ({1:N0} bytes)' -f $entry.FullName, $entry.Length))
            }
        } finally {
            $archive.Dispose()
        }
    }
    default {
        $preview = if ($text) { $text.Substring(0, [Math]::Min(2000, $text.Length)) } else { '(not valid UTF-8)' }
        $outline.Add('First bytes (hex):')
        $outline.Add([System.BitConverter]::ToString($bytes[0..([Math]::Min(63, $bytes.Length - 1))]))
        $outline.Add('')
        $outline.Add('Text preview:')
        $outline.Add($preview)
    }
}

# --- docs/spcf-schema.md ----------------------------------------------------

$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add('# .spcf structure')
$doc.Add('')
$doc.Add("<!-- Generated by tools/emit-spcf.ps1 on $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')). -->")
$doc.Add('')
$doc.Add('Observed structure of one real export. `.spcf` has no published schema; this is what')
$doc.Add('the merge step is built against.')
$doc.Add('')
$doc.Add('| | |')
$doc.Add('|---|---|')
$doc.Add("| Source | `$($sourceItem.Name)` |")
$doc.Add("| Size | $('{0:N0}' -f $sourceItem.Length) bytes |")
$doc.Add("| Format | **$format** |")
$doc.Add("| Leading bytes | `$magic` |")
$doc.Add('')
$doc.Add('## Structure')
$doc.Add('')
$doc.Add('```')
foreach ($line in $outline) { $doc.Add($line) }
$doc.Add('```')
$doc.Add('')
$doc.Add('## Needed for the merge')
$doc.Add('')
$doc.Add('1. The profile list, and which entry is Global Default.')
$doc.Add('2. How an input (a physical button) is identified.')
$doc.Add('3. How a keyboard output encodes key and modifiers: HID usage codes, virtual key')
$doc.Add('   codes, or names.')
$doc.Add('4. How press and release outputs are distinguished, and where the auto-release flag')
$doc.Add('   lives. This decides whether `tapHold` can work.')
$doc.Add('5. Any checksum, length prefix, or id sequence that must be recomputed on write.')
$doc.Add('')

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SchemaDoc) | Out-Null
Set-Content -LiteralPath $SchemaDoc -Value ($doc -join "`r`n") -Encoding UTF8

Write-Host "Wrote docs/spcf-schema.md ($($outline.Count) lines)" -ForegroundColor Green
Write-Host ''

if ($Merge) {
    Write-Host 'Merge is gated.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Writing a profile guessed from an unverified structure can destroy the profiles'
    Write-Host '  already on the mouse. Confirm the five points in the "Needed for the merge"'
    Write-Host '  section of docs/spcf-schema.md first.'
    Write-Host ''
    Write-Host '  Until then use docs/control-panel-entry-sheet.md.'
    Write-Host ''
    exit 2
}
