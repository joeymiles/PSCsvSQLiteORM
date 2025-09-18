param(
    [Parameter(Mandatory)]
    [string]$NuGetApiKey,
    [string]$Repository = 'PSGallery',
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

# Module details
$moduleName = 'PSCsvSQLiteORM'
$root = $PSScriptRoot

# First, ensure the module is built
Write-Host "Building module first..." -ForegroundColor Cyan
& (Join-Path $root 'build-and-test.ps1')

# Get version from the built module
$builtManifestPath = Get-ChildItem -Path C:\Users\Jaga\Documents\Scripts\PSCsvSqliteORM\PSCsvSQLiteORM\output\PSCsvSQLiteORM\3.1.3\PSCsvSQLiteORM.psd1 -Recurse | 
    Sort-Object -Property DirectoryName -Descending | 
    Select-Object -First 1

if (-not $builtManifestPath) {
    throw "Could not find built module manifest. Run build-and-test.ps1 first."
}

$manifestInfo = Test-ModuleManifest -Path $builtManifestPath.FullName
$version = $manifestInfo.Version.ToString()
$moduleBase = $builtManifestPath.DirectoryName

Write-Host "Preparing to publish $moduleName v$version from $moduleBase" -ForegroundColor Green

# Normalize API key
$NuGetApiKey = $NuGetApiKey.Trim()
if ([string]::IsNullOrWhiteSpace($NuGetApiKey)) { 
    throw "NuGetApiKey is empty after trim." 
}

Write-Host ("Using API key: {0}**** (len={1})" -f $NuGetApiKey.Substring(0,[Math]::Min(6,$NuGetApiKey.Length)), $NuGetApiKey.Length)

# Publish the module
$publishParams = @{
    Path = $moduleBase
    NuGetApiKey = $NuGetApiKey
    Repository = $Repository
    Verbose = $true
}

if ($WhatIf) { 
    $publishParams['WhatIf'] = $true 
}

try {
    Write-Host "Publishing module..." -ForegroundColor Cyan
    Publish-Module @publishParams
    Write-Host "Successfully published $moduleName v$version to $Repository!" -ForegroundColor Green
}
catch {
    $msg = $_.Exception.Message
    if ($msg -match '403.*API key is invalid|Forbidden') {
        Write-Error "Failed to publish: 403 Forbidden. Your API key is invalid/expired or lacks permission."
        Write-Host "Please regenerate a PowerShell Gallery API key with 'Push new packages and package updates' permission." -ForegroundColor Yellow
    }
    elseif ($msg -match 'already exists') {
        Write-Warning "Version $version already exists in the repository. Consider incrementing the version number."
    }
    else {
        Write-Error "Failed to publish module: $msg"
    }
    throw
}