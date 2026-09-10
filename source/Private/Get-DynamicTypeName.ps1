# [A] Private helpers for dynamic model naming, the per-database model registry and the per-session model
# directory (TASK A2: BUG-002, BUG-017, BUG-018, BUG-036). Not exported.

# First 8 hex characters of the MD5 of $Text. Used to make generated type and file names unique.
function Get-DynamicNameHash {
    param([Parameter(Mandatory)][string]$Text)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try { $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) }
    finally { $md5.Dispose() }
    return (($bytes[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Normalized registry key for a database path (absolute, lower case) so that .\a.db and C:\x\a.db map to one model set.
function Get-DynamicDatabaseKey {
    param([Parameter(Mandatory)][string]$Database)
    $full = $Database
    try { $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Database) } catch { $full = $Database }
    return $full.ToLowerInvariant()
}

# Derives the PowerShell type name for a table. Simple names (letters, digits and single underscores, starting with a
# letter) keep the readable PascalCase form (assets -> DynamicAssets, user_assets -> DynamicUserAssets). Any other name
# is lossy to PascalCase, so a hash of the raw table name is appended (user-assets -> DynamicUserAssets_<hash>) to
# keep the derivation injective. New-DynamicModel adds a further suffix when the name is reserved or already owned.
function Get-DynamicTypeName {
    param([Parameter(Mandatory)][string]$TableName)
    $words = @(($TableName -replace '[^A-Za-z0-9]+', ' ') -split '\s+' | Where-Object { $_ })
    $pascal = 'Model'
    if ($words.Count -gt 0) { $pascal = ($words | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }) -join '' }
    if ($pascal -match '^[0-9]') { $pascal = '_' + $pascal }
    $typeName = 'Dynamic' + $pascal
    if ($TableName -notmatch '^[A-Za-z][A-Za-z0-9]*(_[A-Za-z0-9]+)*$') {
        $typeName += '_' + (Get-DynamicNameHash -Text $TableName)
    }
    return $typeName
}

# Per-session directory that receives the generated dyn_*.ps1 files. Unique per process and module instance so two
# sessions (or two imports) sharing the same TEMP never overwrite each other's files. Removed when the module unloads.
function Get-DynamicModelDirectory {
    if (-not $script:DynamicModelDir) {
        $script:DynamicModelDir = Join-Path $env:TEMP ("PSCsvSQLiteORM_{0}_{1}" -f $PID, ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    }
    if (-not (Test-Path -LiteralPath $script:DynamicModelDir)) {
        New-Item -ItemType Directory -Path $script:DynamicModelDir -Force | Out-Null
    }
    return $script:DynamicModelDir
}

# Registers cleanup when the module is removed (Remove-Module / Import-Module -Force): pooled SQLite connections are
# closed and disposed so the database files are unlocked (BUG-048), then the generated model files are deleted.
if ($ExecutionContext.SessionState.Module) {
    $ExecutionContext.SessionState.Module.OnRemove = {
        try { Close-DbConnections } catch { Write-Verbose "OnRemove: Close-DbConnections failed: $($_.Exception.Message)" }
        if ($script:DynamicModelDir -and (Test-Path -LiteralPath $script:DynamicModelDir)) {
            Remove-Item -LiteralPath $script:DynamicModelDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
