# Publishes the module that build-module.ps1 produces from THIS checkout.
# Every path is resolved from $PSScriptRoot, the version comes from source\PSCsvSQLiteORM.psd1, and the
# script refuses to publish a working tree with uncommitted changes so a release always matches a commit.
param(
    [Parameter(Mandatory)]
    [string]$NuGetApiKey,
    [string]$Repository = 'PSGallery',
    [switch]$WhatIf,
    # Reuse an existing output\ build instead of running build-module.ps1 first.
    [switch]$SkipBuild,
    # Publish even when git reports uncommitted or untracked files (or the checkout is not a git repository).
    [switch]$AllowDirty
)

$ErrorActionPreference = 'Stop'

# Module details
$moduleName = 'PSCsvSQLiteORM'
$root = $PSScriptRoot
$sourceManifest = Join-Path (Join-Path $root 'source') "$moduleName.psd1"

# Never publish code that exists in no commit: the working tree must be clean.
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    if (-not $AllowDirty) { throw "git was not found, so the working tree cannot be verified as clean. Pass -AllowDirty to publish anyway." }
    Write-Warning "git was not found; skipping the clean working tree check."
}
else {
    # Windows PowerShell 5.1 turns redirected native stderr into a terminating error under 'Stop',
    # so run git with a local 'Continue' preference and judge it by its exit code.
    $gitStatus = @(& { $ErrorActionPreference = 'Continue'; & $git.Source -C $root status --porcelain 2>&1 } | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        if (-not $AllowDirty) { throw "'$root' is not a git repository, so the working tree cannot be verified as clean. Pass -AllowDirty to publish anyway." }
        Write-Warning "'$root' is not a git repository; skipping the clean working tree check."
    }
    elseif ($gitStatus.Count -gt 0) {
        $message = "Refusing to publish: the working tree at '$root' has uncommitted or untracked changes. Commit or stash them first (or pass -AllowDirty)."
        if (-not $AllowDirty) { throw ($message + "`n" + ($gitStatus -join "`n")) }
        Write-Warning $message
    }
}

# Build from this checkout with the committed build script.
if (-not $SkipBuild) {
    Write-Host "Building module first..." -ForegroundColor Cyan
    & (Join-Path $root 'build-module.ps1')
}

# The source manifest is the single place the version lives; publish exactly that build.
$version = [string](Import-PowerShellDataFile -Path $sourceManifest).ModuleVersion
if ([string]::IsNullOrWhiteSpace($version)) {
    throw "ModuleVersion is missing from $sourceManifest"
}
$moduleBase = Join-Path (Join-Path (Join-Path $root 'output') $moduleName) $version
$builtManifestPath = Join-Path $moduleBase "$moduleName.psd1"

if (-not (Test-Path -LiteralPath $builtManifestPath)) {
    throw "Could not find built module manifest at '$builtManifestPath'. Run build-module.ps1 first."
}

$manifestInfo = Test-ModuleManifest -Path $builtManifestPath
if ([string]$manifestInfo.Version -ne $version) {
    throw "Built manifest version $($manifestInfo.Version) does not match source manifest version $version. Rebuild first."
}

Write-Host "Preparing to publish $moduleName v$version from $moduleBase" -ForegroundColor Green

# Normalize API key. Never echo any part of it.
$NuGetApiKey = $NuGetApiKey.Trim()
if ([string]::IsNullOrWhiteSpace($NuGetApiKey)) {
    throw "NuGetApiKey is empty after trim."
}

Write-Host ("Using API key (len={0})" -f $NuGetApiKey.Length)

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
