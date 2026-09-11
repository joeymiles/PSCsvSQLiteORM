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
    $aboutTopic = "about_$ModuleName.help.txt"

    $docsSrc = Join-Path $PSScriptRoot 'docs'
    if (Test-Path $docsSrc) {
        Copy-Item -Recurse -Force $docsSrc (Join-Path $builtVersionPath 'docs')

        # Get-Help searches the module's culture folder for about topics, never docs\. Without this copy
        # Get-Help about_PSCsvSQLiteORM silently answers from whatever older copy of the module happens to
        # sit on PSModulePath instead of from the build under test (E2E1-031).
        $aboutSrc = Join-Path $docsSrc $aboutTopic
        if (Test-Path -LiteralPath $aboutSrc) {
            $cultureDir = Join-Path $builtVersionPath 'en-US'
            if (-not (Test-Path -LiteralPath $cultureDir)) {
                New-Item -ItemType Directory -Path $cultureDir | Out-Null
            }
            Copy-Item -Force -LiteralPath $aboutSrc -Destination (Join-Path $cultureDir $aboutTopic)
        }
    }

    $examplesSrc = Join-Path $SourcePath 'Examples'
    if (Test-Path $examplesSrc) {
        Copy-Item -Recurse -Force $examplesSrc (Join-Path $builtVersionPath 'Examples')
    }

    # Verify the extra content really shipped. Until this check existed, a build whose docs\ or
    # source\Examples\ folder was missing (or whose copy failed) still reported success, and the module it
    # produced broke README's promise of Examples\orm.settings.ps1 and carried no about topic (E2E1-031).
    $requiredBuiltFiles = @(
        (Join-Path (Join-Path $builtVersionPath 'docs') $aboutTopic),
        (Join-Path (Join-Path $builtVersionPath 'en-US') $aboutTopic),
        (Join-Path (Join-Path $builtVersionPath 'Examples') 'orm.settings.ps1')
    )
    # Every file under docs\ and source\Examples\ must have a counterpart in the built module, so content
    # added later is covered without anyone having to extend the list above.
    $contentPairs = @()
    $contentPairs += [PSCustomObject]@{ Source = $docsSrc; Target = (Join-Path $builtVersionPath 'docs') }
    $contentPairs += [PSCustomObject]@{ Source = $examplesSrc; Target = (Join-Path $builtVersionPath 'Examples') }
    foreach ($pair in $contentPairs) {
        if (-not (Test-Path -LiteralPath $pair.Source)) { continue }
        foreach ($sourceFile in @(Get-ChildItem -LiteralPath $pair.Source -Recurse -File)) {
            $relative = $sourceFile.FullName.Substring($pair.Source.Length).TrimStart('\', '/')
            $requiredBuiltFiles += (Join-Path $pair.Target $relative)
        }
    }
    $missingContent = @($requiredBuiltFiles | Sort-Object -Unique | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missingContent.Count -gt 0) {
        throw "Build incomplete: the built module is missing $($missingContent -join ', '). Check that docs\ and source\Examples\ exist and were copied into $builtVersionPath."
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
