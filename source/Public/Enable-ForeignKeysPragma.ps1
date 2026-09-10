function Enable-ForeignKeysPragma {
    param([Parameter(Mandatory)][string]$Database)
    # BUG-008: foreign_keys is a per-connection pragma and PSSQLite's Invoke-SqliteQuery opens a
    # new connection for every call, so enabling it here cannot enforce anything for later
    # statements. Invoke-DbQuery prefixes every fallback batch with the pragma instead. This
    # function only verifies once per database that the fallback can apply the pragma, and its
    # log line must not claim that enforcement is in effect.
    $key = Resolve-DbPath -Database $Database
    if ($script:PragmaSet[$key]) { return }
    try {
        $r = @(Invoke-SqliteQuery -DataSource $Database -Query 'PRAGMA foreign_keys = ON; PRAGMA foreign_keys;' -ErrorAction Stop)
        $script:PragmaSet[$key] = $true
        $state = 'unknown'
        if ($r.Count -gt 0) { $firstProp = $r[0].PSObject.Properties | Select-Object -First 1; if ($firstProp) { $state = [string]$firstProp.Value } }
        Write-DbLog DEBUG "PRAGMA foreign_keys supported by fallback (probe connection reported $state); Invoke-DbQuery enables it per statement batch"
    }
    catch { Write-DbLog WARN "Unable to set PRAGMA foreign_keys in fallback" $_.Exception }
}

