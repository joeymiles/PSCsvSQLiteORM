function Get-DbConnection {
    param([Parameter(Mandatory)][string]$Database)
    # BUG-014: the canonical path is used for the Data Source and as the pool key
    $key = Resolve-DbPath -Database $Database
    if ($script:DbPool.ContainsKey($key)) {
        $existing = $script:DbPool[$key]
        if ($existing -and $existing.State -eq 'Open') { return $existing }
        # BUG-049: evict a closed/broken (or cached $null) entry and reopen below
        if ($existing) { try { $existing.Dispose() } catch { } }
        $script:DbPool.Remove($key)
        Write-DbLog DEBUG "Evicted non-open pooled connection for $key"
    }
    # BASE-02: PSSQLite already loads System.Data.SQLite; detect the type instead of Add-Type -AssemblyName
    $connType = Get-SQLiteConnectionType
    if (-not $connType) { Write-DbLog WARN "System.Data.SQLite not available; using PSSQLite only."; return $null }
    # BUG-072: build the connection string with the builder so ';' in the path is quoted
    $csb = New-Object System.Data.SQLite.SQLiteConnectionStringBuilder
    $csb.DataSource = $key
    $csb.Version = 3
    $conn = New-Object System.Data.SQLite.SQLiteConnection($csb.ConnectionString)
    $conn.Open()
    $cmd = $conn.CreateCommand(); $cmd.CommandText = 'PRAGMA foreign_keys = ON;'; [void]$cmd.ExecuteNonQuery(); $cmd.Dispose()
    $script:DbPool[$key] = $conn
    return $conn
}
