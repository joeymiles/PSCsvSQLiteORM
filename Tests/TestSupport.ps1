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
