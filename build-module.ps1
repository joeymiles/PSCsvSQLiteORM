# Simple build script that bypasses Test-ModuleManifest issues
param(
    [string]$Version = '3.1.3'
)

$ModuleName = 'PSCsvSQLiteORM'
$SourcePath = Join-Path $PSScriptRoot 'source'
$OutputPath = Join-Path $PSScriptRoot 'output'

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
}

Write-Host "Building $ModuleName version $Version to $OutputPath" -ForegroundColor Green

try {
    # Import ModuleBuilder
    Import-Module ModuleBuilder -ErrorAction Stop
    
    # Build with explicit version
    Build-Module -SourcePath $SourcePath -OutputDirectory $OutputPath -Version $Version -Verbose
    
    # Copy docs and examples
    $builtBase = Join-Path $OutputPath $ModuleName
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
    
    # Test import
    Write-Host "Testing module import..." -ForegroundColor Yellow
    Import-Module $builtBase -Force -Verbose:$false
    $module = Get-Module $ModuleName
    if ($module) {
        Write-Host "Module imported successfully. Version: $($module.Version)" -ForegroundColor Green
        Write-Host "Exported commands: $($module.ExportedCommands.Count)" -ForegroundColor Cyan
    } else {
        Write-Warning "Module import test failed"
    }
}
catch {
    Write-Error "Build failed: $_"
    throw
}