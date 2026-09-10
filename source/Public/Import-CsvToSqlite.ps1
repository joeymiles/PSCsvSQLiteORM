function Import-CsvToSqlite {
    param (
        [Parameter(Mandatory)][string]$CsvPath,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$TableName,
        [string[]]$ForeignKeys = @(),
        [string[]]$NullTokens = @('', 'NULL', 'N/A', 'NaN'),
        [hashtable]$BoolTokens = @{ true = @('true', '1', 'yes', 'y'); false = @('false', '0', 'no', 'n') },
        [ValidateSet('Strict', 'Relaxed', 'AppendOnly')][string]$SchemaMode = 'Relaxed',
        [int]$BatchSize = 0  # 0 = all
    )
    $csv = Import-Csv -Path $CsvPath
    if (-not $csv) { throw "CSV file is empty or invalid." }
    
    $headers = $csv[0].PSObject.Properties.Name
    if (-not $headers -or $headers.Count -eq 0) { throw "No columns in CSV." }

    # Normalize null tokens
    foreach ($row in $csv) {
        foreach ($p in $row.PSObject.Properties.Name) {
            $val = $row.$p
            if ($NullTokens -contains $val) { $row.$p = $null; continue }
        }
    }

    # Normalize bool tokens per column: a column is boolean only when every
    # non-null value is a bool token (and there is at least one such value).
    # Applying tokens per cell rewrote ordinary text such as 'NO', 'Y' or 'N'.
    $trueTokens = @(); $falseTokens = @()
    if ($BoolTokens) {
        if ($BoolTokens.true) { $trueTokens = @($BoolTokens.true | ForEach-Object { "$_".ToLowerInvariant() }) }
        if ($BoolTokens.false) { $falseTokens = @($BoolTokens.false | ForEach-Object { "$_".ToLowerInvariant() }) }
    }
    if ($trueTokens.Count -gt 0 -or $falseTokens.Count -gt 0) {
        foreach ($p in $headers) {
            $isBoolColumn = $true; $seen = $false
            foreach ($row in $csv) {
                $val = $row.$p
                if ($null -eq $val) { continue }
                if ($val -isnot [string]) { $isBoolColumn = $false; break }
                $lc = $val.ToLowerInvariant()
                if ($trueTokens -contains $lc -or $falseTokens -contains $lc) { $seen = $true }
                else { $isBoolColumn = $false; break }
            }
            if (-not ($isBoolColumn -and $seen)) { continue }
            foreach ($row in $csv) {
                $val = $row.$p
                if ($null -eq $val) { continue }
                if ($trueTokens -contains $val.ToLowerInvariant()) { $row.$p = 1 } else { $row.$p = 0 }
            }
        }
    }

    $columnTypes = Test-ColumnTypes -Csv $csv -Headers $headers
    foreach ($h in $headers) { if (-not $columnTypes[$h]) { $columnTypes[$h] = 'TEXT' } }

    $quotedCols = ($headers | ForEach-Object { "$(ConvertTo-Ident $_) $($columnTypes[$_])" }) -join ", "
    # Handle schema creation based on SchemaMode
    if ($SchemaMode -ne 'AppendOnly') {
        if (-not [string]::IsNullOrWhiteSpace($quotedCols)) {
            $createQuery = "CREATE TABLE IF NOT EXISTS $(ConvertTo-Ident $TableName) ($quotedCols)"
            Write-DbLog DEBUG "Creating table with query: $createQuery"
            Invoke-DbQuery -Database $Database -Query $createQuery -NonQuery | Out-Null
        }
    } else {
        # AppendOnly: ensure table exists; do not create
        $exists = Invoke-DbQuery -Database $Database -Query "SELECT name FROM sqlite_master WHERE type='table' AND name=@t" -SqlParameters @{ t = $TableName }
        if (-not $exists -or $exists.Count -eq 0) { throw "AppendOnly mode: table '$TableName' does not exist." }
    }

    # Evolve schema
    $existing = Invoke-DbQuery -Database $Database -Query "PRAGMA table_info($(ConvertTo-Ident $TableName))"
    $existingNames = $existing | ForEach-Object { $_.name }
    if ($SchemaMode -in @('Relaxed')) {
        $added = $false
        foreach ($h in $headers) {
            if ($existingNames -notcontains $h) {
                # ALTER TABLE ADD COLUMN cannot add PRIMARY KEY / AUTOINCREMENT / UNIQUE columns;
                # add the bare storage type instead (e.g. 'id' becomes plain INTEGER).
                $addType = $columnTypes[$h] -replace '(?i)\s+(PRIMARY\s+KEY|AUTOINCREMENT|UNIQUE)\b.*$', ''
                if ([string]::IsNullOrWhiteSpace($addType)) { $addType = 'TEXT' }
                $sql = "ALTER TABLE $(ConvertTo-Ident $TableName) ADD COLUMN $(ConvertTo-Ident $h) $addType"
                Invoke-DbQuery -Database $Database -Query $sql -NonQuery | Out-Null
                $added = $true
            }
        }
        if ($added) {
            # Verify the columns really exist before inserting (on Windows PowerShell 5.1 the
            # PSSQLite fallback reports SQL errors non-terminatingly).
            $existing = Invoke-DbQuery -Database $Database -Query "PRAGMA table_info($(ConvertTo-Ident $TableName))"
            $existingNames = $existing | ForEach-Object { $_.name }
            foreach ($h in $headers) { if ($existingNames -notcontains $h) { throw "Relaxed mode: failed to add column $h to $TableName" } }
        }
    }
    elseif ($SchemaMode -eq 'Strict') {
        foreach ($h in $headers) { if ($existingNames -notcontains $h) { throw "Strict mode: missing column $h in $TableName" } }
    }
    elseif ($SchemaMode -eq 'AppendOnly') {
        # No schema changes allowed; every CSV column must already exist in the table
        foreach ($h in $headers) { if ($existingNames -notcontains $h) { throw "AppendOnly mode: column $h does not exist in table $TableName" } }
    }

    # Insert data
    $tx = Start-DbTransaction -Database $Database
    try {
        $count = 0
        foreach ($row in $csv) {
            $keys = $row.PSObject.Properties.Name
            $columns = (($keys | ForEach-Object { ConvertTo-Ident $_ })) -join ", "
            # Positional parameter names (@p0, @p1, ...) cannot collide the way sanitized
            # header text did ('a b', 'a_b' and 'a-b' all became @a_b).
            $paramNames = ConvertTo-ParamMap -Columns $keys
            $placeholders = (($keys | ForEach-Object { "@$($paramNames[$_])" })) -join ", "
            $query = "INSERT INTO $(ConvertTo-Ident $TableName) ($columns) VALUES ($placeholders)"
            $params = @{}
            foreach ($k in $keys) {
                $paramName = $paramNames[$k]
                $params[$paramName] = $row.$k
            }
            [void](Invoke-DbQuery -Database $Database -Query $query -SqlParameters $params -NonQuery -Transaction $tx)
            $count++
            if ($BatchSize -gt 0 -and ($count % $BatchSize) -eq 0) {
                $pct = [int](($count / [double]$csv.Count) * 100)
                Write-Progress -Activity "Importing $TableName" -Status "$count / $($csv.Count)" -PercentComplete $pct
            }
        }
        Complete-DbTransaction -Database $Database -Transaction $tx
    }
    catch { Undo-DbTransaction -Database $Database -Transaction $tx; throw }

    Update-DbCatalog -Database $Database -SourceCsvPath $CsvPath -Table $TableName
    return $headers
}
