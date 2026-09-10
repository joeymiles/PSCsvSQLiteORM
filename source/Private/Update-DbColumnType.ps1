function Update-DbColumnType {
    <#
    .SYNOPSIS
        Widens the declared type of one or more columns by rebuilding the table.
    .DESCRIPTION
        SQLite cannot ALTER a column type, so the table is rebuilt in place:
        a copy with the new column types is created, the rows are copied, the
        old table is dropped and the copy is renamed. Indexes and triggers that
        belong to the table are re-created afterwards. Foreign key enforcement
        is switched off for the duration of the rebuild so child tables keep
        their rows and their references to the table name.
        ColumnTypes maps column name to the new storage type (for example
        @{ zip = 'TEXT' }). A PRIMARY KEY column loses AUTOINCREMENT when it
        stops being INTEGER.
    #>
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][hashtable]$ColumnTypes
    )
    $quotedTable = ConvertTo-Ident $Table
    $meta = @(Invoke-DbQuery -Database $Database -Query "SELECT sql FROM sqlite_master WHERE type='table' AND name=@t" -SqlParameters @{ t = $Table })
    if ($meta.Count -eq 0 -or -not $meta[0].sql) { throw "Cannot widen columns of table '$Table': table definition not found" }
    $originalSql = [string]$meta[0].sql
    $newSql = $originalSql

    foreach ($col in @($ColumnTypes.Keys)) {
        $newType = [string]$ColumnTypes[$col]
        if ($newType -notmatch '^[A-Za-z]+$') { throw "Cannot widen column '$col' of table '$Table': invalid type '$newType'" }
        $identPattern = '(?:"' + [regex]::Escape($col) + '"|' + [regex]::Escape($col) + ')'
        # "<col> <type>" right after "(" or "," at the start of a column definition
        $defPattern = '(?i)([(,]\s*)(' + $identPattern + ')\s+([A-Za-z]+(?:\s*\([^)]*\))?)'
        $m = [regex]::Match($newSql, $defPattern)
        if (-not $m.Success) { throw "Cannot widen column '$col' of table '$Table': column definition not recognised in: $originalSql" }
        $replacement = $m.Groups[1].Value + $m.Groups[2].Value + ' ' + $newType
        $newSql = $newSql.Substring(0, $m.Index) + $replacement + $newSql.Substring($m.Index + $m.Length)
        if ($newType -notmatch '(?i)INT') {
            # AUTOINCREMENT is only legal on INTEGER PRIMARY KEY
            $autoPattern = '(?i)(' + $identPattern + '\s+' + [regex]::Escape($newType) + '\s+PRIMARY\s+KEY)\s+AUTOINCREMENT'
            $newSql = [regex]::Replace($newSql, $autoPattern, '$1')
        }
    }

    $tmpName = $Table + '__widen_tmp'
    $quotedTmp = ConvertTo-Ident $tmpName
    $headPattern = '(?i)^\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:"(?:[^"]|"")+"|\[[^\]]+\]|`[^`]+`|[^\s(]+)'
    if ($newSql -notmatch $headPattern) { throw "Cannot widen columns of table '$Table': table definition not recognised in: $originalSql" }
    $createTmp = [regex]::Replace($newSql, $headPattern, ('CREATE TABLE ' + $quotedTmp), 1)

    $columns = @(Invoke-DbQuery -Database $Database -Query "PRAGMA table_info($quotedTable)" | ForEach-Object { ConvertTo-Ident $_.name })
    $colList = $columns -join ', '
    $dependents = @(Invoke-DbQuery -Database $Database -Query "SELECT sql FROM sqlite_master WHERE tbl_name=@t AND type IN ('index','trigger') AND sql IS NOT NULL" -SqlParameters @{ t = $Table })

    $steps = New-Object System.Collections.Generic.List[string]
    $steps.Add('PRAGMA foreign_keys = OFF;')
    $steps.Add('BEGIN;')
    $steps.Add("DROP TABLE IF EXISTS $quotedTmp;")
    $steps.Add($createTmp + ';')
    $steps.Add("INSERT INTO $quotedTmp ($colList) SELECT $colList FROM $quotedTable;")
    $steps.Add("DROP TABLE $quotedTable;")
    $steps.Add("ALTER TABLE $quotedTmp RENAME TO $quotedTable;")
    foreach ($d in $dependents) { $steps.Add(([string]$d.sql) + ';') }
    $steps.Add('COMMIT;')
    $steps.Add('PRAGMA foreign_keys = ON;')
    $script = $steps -join "`n"
    Write-DbLog INFO "Rebuilding table $Table to widen columns: $(($ColumnTypes.Keys | ForEach-Object { "$_=$($ColumnTypes[$_])" }) -join ', ')"
    Invoke-DbQuery -Database $Database -Query $script -NonQuery | Out-Null

    # Verify (on Windows PowerShell 5.1 the PSSQLite fallback reports SQL errors non-terminatingly)
    $after = @(Invoke-DbQuery -Database $Database -Query "PRAGMA table_info($quotedTable)")
    foreach ($col in @($ColumnTypes.Keys)) {
        $info = $after | Where-Object { $_.name -eq $col } | Select-Object -First 1
        if (-not $info -or "$($info.type)" -ne [string]$ColumnTypes[$col]) {
            throw "Failed to widen column '$col' of table '$Table' to $($ColumnTypes[$col])"
        }
    }
}
