# Shared test support for PSCsvSQLiteORM (worker A helper). Dot-source this file from a test; it is not a
# Pester container (the name does not end in .Tests.ps1, so Invoke-Pester never discovers it).
#
# BUG-077: the tests used to import the unversioned folder output\PSCsvSQLiteORM. PowerShell resolves that
# to the HIGHEST version folder present, and neither ModuleBuilder nor the build script used to remove
# folders of other versions, so once a higher version had been built the whole suite silently tested a
# stale copy. Get-OrmBuiltManifestPath instead returns the manifest of the build for the version declared in
# source\PSCsvSQLiteORM.psd1 (the version the build just produced) and fails loudly when it is missing.
#
# Runs on Windows PowerShell 5.1 and PowerShell 7: paths are joined two pieces at a time because the
# three-argument Join-Path form does not exist on 5.1.

function Get-OrmBuiltManifestPath {
    [CmdletBinding()]
    param(
        # Repository root (the folder holding source\ and output\). Defaults to the parent of the Tests folder.
        [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
    )
    $moduleName = 'PSCsvSQLiteORM'
    $sourceManifest = Join-Path (Join-Path $RepoRoot 'source') ($moduleName + '.psd1')
    $version = [string](Import-PowerShellDataFile -Path $sourceManifest).ModuleVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "ModuleVersion is missing from $sourceManifest"
    }
    $builtFolder = Join-Path (Join-Path (Join-Path $RepoRoot 'output') $moduleName) $version
    $builtManifest = Join-Path $builtFolder ($moduleName + '.psd1')
    if (-not (Test-Path -LiteralPath $builtManifest)) {
        throw "Built module $moduleName $version not found at $builtManifest. Build the module first (build-module.ps1) so the tests exercise the version declared in the source manifest."
    }
    return $builtManifest
}

function Get-OrmDocPath {
    <#
        Paths of the two documents the suite executes: the Quick Start and the reference it links to.
        Pass -Name 'readme' or 'reference'; omit it to get both, README first.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('readme', 'reference')][string]$Name,
        [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
    )
    $map = [ordered]@{
        readme    = Join-Path $RepoRoot 'README.md'
        reference = Join-Path (Join-Path $RepoRoot 'docs') 'reference.md'
    }
    if ($Name) { return $map[$Name] }
    return @($map.Values)
}

function Get-OrmDocText {
    <#
        Raw text of one document, or of the whole documentation set joined together. Content assertions use
        the set so that moving a paragraph between the Quick Start and the reference does not fail a test
        that only cares whether the behaviour is documented somewhere a reader will find it.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('readme', 'reference')][string]$Name,
        [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
    )
    $paths = if ($Name) { @(Get-OrmDocPath -Name $Name -RepoRoot $RepoRoot) } else { @(Get-OrmDocPath -RepoRoot $RepoRoot) }
    $parts = foreach ($p in $paths) { Get-Content -LiteralPath $p -Raw }
    return ($parts -join "`n")
}

function Get-OrmDocCodeBlock {
    <#
        The PowerShell code blocks under a markdown heading, found by the heading text rather than by the
        ordinal position of the block in the file, so that adding or reordering sections cannot silently
        point a test at the wrong code. -Heading matches the part of the heading line after the '#'
        characters, case-insensitively, as a substring ('3. Import CSV Data').
        Returns the block bodies; throws when the heading is absent or carries no PowerShell block.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Heading,
        [ValidateSet('readme', 'reference')][string]$Name = 'readme',
        [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
    )
    $path = Get-OrmDocPath -Name $Name -RepoRoot $RepoRoot
    $lines = Get-Content -LiteralPath $path
    $start = -1
    $level = 0
    $inFence = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        # A fenced block's PowerShell comments also begin with '#', so headings are only read outside a fence.
        if ($lines[$i] -match '^\s*```') { $inFence = -not $inFence; continue }
        if (-not $inFence -and $lines[$i] -match '^(#{1,6})\s+(.*?)\s*$') {
            $thisLevel = $Matches[1].Length
            $text = $Matches[2]
            if ($start -ge 0 -and $thisLevel -le $level) { break }
            # -like would read '[' and ']' in a heading as a wildcard, so the match is a plain substring test.
            if ($start -lt 0 -and $text.IndexOf($Heading, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $start = $i; $level = $thisLevel
            }
        }
    }
    if ($start -lt 0) { throw "Heading '$Heading' not found in $path" }
    $end = if ($i -ge $lines.Count) { $lines.Count } else { $i }
    $section = ($lines[$start..($end - 1)] -join "`n")
    $blocks = @([regex]::Matches($section, '(?s)```powershell\r?\n(.*?)```') | ForEach-Object { $_.Groups[1].Value })
    if ($blocks.Count -eq 0) { throw "Heading '$Heading' in $path contains no PowerShell code block" }
    return , $blocks
}

function Get-OrmDocStatement {
    <#
        The executable statements of the code block(s) under a heading: comment lines, blank lines and any
        line matching -Exclude are dropped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Heading,
        [ValidateSet('readme', 'reference')][string]$Name = 'readme',
        [string[]]$Exclude = @(),
        [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
    )
    $statements = @()
    foreach ($block in (Get-OrmDocCodeBlock -Heading $Heading -Name $Name -RepoRoot $RepoRoot)) {
        foreach ($raw in ($block -split "\r?\n")) {
            $line = $raw.Trim()
            if (-not $line -or $line.StartsWith('#')) { continue }
            $skip = $false
            foreach ($pattern in $Exclude) { if ($line -match $pattern) { $skip = $true; break } }
            if (-not $skip) { $statements += $line }
        }
    }
    return , $statements
}
