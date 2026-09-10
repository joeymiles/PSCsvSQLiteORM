# [A] Private helper for Write-DbLog (TASK A11: BUG-046, BUG-070). Not exported.
#
# Appends one line to the log file without ever throwing: the parent directory is created on first use,
# the text is written as UTF-8 (Windows PowerShell 5.1 would otherwise use the ANSI code page), and a
# named mutex keyed on the log path serialises writers from other sessions so concurrent appends do not
# overwrite each other. Any failure is reported once per path as a warning and then only via Write-Verbose,
# so a bad LogPath (or a global $ErrorActionPreference of Stop) never aborts a database operation.

function Write-DbLogLine {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$Line
    )
    if (-not $script:DbLogFailedPaths) { $script:DbLogFailedPaths = @{} }
    $mutex = $null
    $acquired = $false
    # Exceptions caught below are still recorded in $Error; remember the count so they can be trimmed again.
    $errorCount = $global:Error.Count
    try {
        $fullPath = $Path
        try { $fullPath = [System.IO.Path]::GetFullPath($Path) } catch { $fullPath = $Path }

        $dir = [System.IO.Path]::GetDirectoryName($fullPath)
        if ($dir -and -not [System.IO.Directory]::Exists($dir)) {
            [System.IO.Directory]::CreateDirectory($dir) | Out-Null
        }

        # Mutex names cannot contain path separators: key the name on a hash of the normalised path.
        $mutexName = 'PSCsvSQLiteORM_Log_' + (Get-DbLogPathHash -Text $fullPath.ToLowerInvariant())
        try {
            $mutex = New-Object System.Threading.Mutex($false, $mutexName)
            try { $acquired = $mutex.WaitOne(5000) }
            catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        } catch {
            # Mutex creation can fail under restricted accounts; fall back to an unsynchronised append.
            $mutex = $null
        }

        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $bytes = $utf8.GetBytes($Line + [System.Environment]::NewLine)
        $stream = New-Object System.IO.FileStream(
            $fullPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } finally {
            $stream.Dispose()
        }
        if ($script:DbLogFailedPaths.ContainsKey($fullPath)) { $script:DbLogFailedPaths.Remove($fullPath) }
        return $true
    } catch {
        $reason = $_.Exception.Message
        $key = $Path
        if ($fullPath) { $key = $fullPath }
        if (-not $script:DbLogFailedPaths.ContainsKey($key)) {
            $script:DbLogFailedPaths[$key] = $true
            Write-Warning ("PSCsvSQLiteORM: cannot write to log file '{0}': {1}. Further failures for this path are reported via Write-Verbose only." -f $key, $reason)
        } else {
            Write-Verbose ("PSCsvSQLiteORM: cannot write to log file '{0}': {1}" -f $key, $reason)
        }
        return $false
    } finally {
        if ($mutex) {
            if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
            $mutex.Dispose()
        }
        # Logging is best effort: do not leave the caller's $Error polluted by failures handled here.
        while ($global:Error.Count -gt $errorCount) { $global:Error.RemoveAt(0) }
    }
}

# Hex SHA1 of $Text. Used to derive a mutex name from a log path.
function Get-DbLogPathHash {
    param([Parameter(Mandatory)][string]$Text)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) }
    finally { $sha.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}
