# Simple build script that bypasses Test-ModuleManifest issues.
# Runs from any current directory: every path is resolved from $PSScriptRoot, and the version
# defaults to ModuleVersion in source\PSCsvSQLiteORM.psd1 (pass -Version only to override it).
param(
    [string]$Version
)

$ModuleName = 'PSCsvSQLiteORM'
$SourcePath = Join-Path $PSScriptRoot 'source'
$OutputPath = Join-Path $PSScriptRoot 'output'
$ManifestPath = Join-Path $SourcePath "$ModuleName.psd1"

# The source manifest is the single place the version lives; -Version is an explicit override only.
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = [string](Import-PowerShellDataFile -Path $ManifestPath).ModuleVersion
    if ([string]::IsNullOrWhiteSpace($Version)) {
        throw "ModuleVersion is missing from $ManifestPath"
    }
}

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
}

Write-Host "Building $ModuleName version $Version to $OutputPath" -ForegroundColor Green

try {
    # Import ModuleBuilder. Windows PowerShell 5.1 does not search the PowerShell 7 module path,
    # so fall back to the user's PowerShell 7 module folder when it is not on this host's path.
    if (-not (Get-Module -ListAvailable -Name ModuleBuilder)) {
        $ps7Modules = Join-Path (Join-Path (Join-Path $HOME 'Documents') 'PowerShell') 'Modules'
        if (Test-Path -LiteralPath (Join-Path $ps7Modules 'ModuleBuilder')) {
            $env:PSModulePath = $ps7Modules + [System.IO.Path]::PathSeparator + $env:PSModulePath
        }
    }
    Import-Module ModuleBuilder -ErrorAction Stop

    # Remove every earlier build first. ModuleBuilder only clears output\<Module>\<Version>, so folders of
    # other versions would pile up, and Import-Module on the unversioned output\<Module> folder picks the
    # highest version present rather than the build just made (BUG-077).
    $builtBase = Join-Path $OutputPath $ModuleName
    if (Test-Path -LiteralPath $builtBase) {
        Write-Host "Removing earlier builds from $builtBase" -ForegroundColor Yellow
        Remove-Item -LiteralPath $builtBase -Recurse -Force -ErrorAction Stop
    }

    # Pass the manifest path, not the source folder: with a folder ModuleBuilder resolves the
    # manifest relative to the current location, which fails from any other directory.
    Build-Module -SourcePath $ManifestPath -OutputDirectory $OutputPath -Version $Version -Verbose

    # Copy docs and examples
    $builtVersionPath = Join-Path $builtBase $Version

    $docsSrc = Join-Path $PSScriptRoot 'docs'
    if (Test-Path $docsSrc) {
        Copy-Item -Recurse -Force $docsSrc (Join-Path $builtVersionPath 'docs')
    }

    $examplesSrc = Join-Path $SourcePath 'Examples'
    if (Test-Path $examplesSrc) {
        Copy-Item -Recurse -Force $examplesSrc (Join-Path $builtVersionPath 'Examples')
    }

    Write-Host "Successfully built $ModuleName version $Version" -ForegroundColor Green
    Write-Host "Module location: $builtVersionPath" -ForegroundColor Cyan

    # Test import: validate the copy that was just built, not whatever copy happens to be loaded.
    Write-Host "Testing module import..." -ForegroundColor Yellow
    Get-Module -Name $ModuleName | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $builtVersionPath "$ModuleName.psd1") -Force -Verbose:$false
    $builtVersionFull = (Resolve-Path -LiteralPath $builtVersionPath).ProviderPath.TrimEnd('\')
    $module = @(Get-Module -Name $ModuleName | Where-Object { $_.ModuleBase.TrimEnd('\') -eq $builtVersionFull }) | Select-Object -First 1
    if (-not $module) {
        throw "Module import test failed: $builtVersionPath was not loaded"
    }
    if ([string]$module.Version -ne $Version) {
        throw "Module import test failed: expected version $Version but loaded $($module.Version)"
    }
    $expectedCommands = @(Get-ChildItem -Path (Join-Path $SourcePath 'Public') -Filter '*.ps1' -File).Count
    if ($module.ExportedCommands.Count -ne $expectedCommands) {
        throw "Module import test failed: expected $expectedCommands exported commands but found $($module.ExportedCommands.Count)"
    }
    Write-Host "Module imported successfully. Version: $($module.Version)" -ForegroundColor Green
    Write-Host "Exported commands: $($module.ExportedCommands.Count)" -ForegroundColor Cyan
}
catch {
    Write-Error "Build failed: $_"
    throw
}
