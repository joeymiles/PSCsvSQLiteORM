function Enable-ForeignKeysPragma {
    param([Parameter(Mandatory)][string]$Database)
    $key = Resolve-DbPath -Database $Database
    if ($script:PragmaSet[$key]) { return }
    try {
        Invoke-SqliteQuery -DataSource $Database -Query 'PRAGMA foreign_keys = ON;' -ErrorAction Stop
        $script:PragmaSet[$key] = $true
        Write-DbLog DEBUG "PRAGMA foreign_keys = ON (fallback)"
    }
    catch { Write-DbLog WARN "Unable to set PRAGMA foreign_keys in fallback" $_.Exception }
}

