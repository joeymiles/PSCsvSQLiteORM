function Import-CsvToSqlite {
    # E2E1-004: the import declares -WhatIf itself. Without it the helpers it calls that do declare
    # ShouldProcess (Start-DbTransaction, Update-DbCatalog) skipped themselves under an inherited
    # $WhatIfPreference while every row was still written, so -WhatIf produced an untransacted,
    # uncataloged import instead of a preview. ConfirmImpact is Medium so the default
    # $ConfirmPreference never prompts.
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param (
        [Parameter(Mandatory)][string]$CsvPath,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$TableName,
        [string[]]$ForeignKeys = @(),
        [string[]]$NullTokens = @('', 'NULL', 'N/A', 'NaN'),
        # Null tokens match exactly (case-sensitive) by default so real values such as a
        # surname 'Null' or a code 'nan' are kept (BUG-052). Set this to restore the old
        # case-insensitive matching.
        [switch]$IgnoreNullTokenCase,
        [hashtable]$BoolTokens = @{ true = @('true', '1', 'yes', 'y'); false = @('false', '0', 'no', 'n') },
        [ValidateSet('Strict', 'Relaxed', 'AppendOnly')][string]$SchemaMode = 'Relaxed',
        [int]$BatchSize = 0  # 0 = all
    )
    # E2E1-027: a header is trimmed before it becomes a column name, so the table name is trimmed
    # too. Without this 'spaced ' created a table literally called "spaced " and the next import
    # spelled without the trailing space silently created a second, separate table.
    $TableName = "$TableName".Trim()
    if ($TableName -eq '') { throw "TableName is empty." }
    # -LiteralPath: '[' and ']' in the file name are not wildcards (BUG-071).
    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) { throw "CSV file not found: $CsvPath" }
    # BUG-007: @() so a one-row CSV (a bare PSCustomObject on 5.1, where .Count is $null) is counted
    $csv = @(Import-Csv -LiteralPath $CsvPath)
    # The header line itself is read in both branches: Import-Csv returns nothing at all for a
    # header-only file (BUG-054), and it hides a nameless column behind a generated name (E2E1-026).
    $headerLine = Get-Content -LiteralPath $CsvPath -TotalCount 1
    if ($csv.Count -gt 0) {
        $rawHeaders = @($csv[0].PSObject.Properties.Name)
    }
    else {
        # Read the header line so the table can still be created from a template CSV (BUG-054);
        # a zero-byte file is an error.
        if ([string]::IsNullOrWhiteSpace("$headerLine")) { throw "CSV file is empty: $CsvPath" }
        $rawHeaders = @((ConvertFrom-Csv -InputObject @("$headerLine", "$headerLine"))[0].PSObject.Properties.Name)
    }
    if ($rawHeaders.Count -eq 0) { throw "No columns in CSV." }
    $total = [math]::Max(1, $csv.Count)

    # E2E1-026: Import-Csv and ConvertFrom-Csv substitute a generated name ('H1', 'H2', ...) for a
    # missing header and only write a PowerShell warning, so the empty-column-name guard below never
    # saw a nameless column: its data landed in a column called H1 and the caller got no error.
    # Re-read the header line and check the names the file really carries. Parsing that line as DATA
    # with positional field names keeps quoting and embedded commas working.
    $positionalNames = @(0..($rawHeaders.Count - 1) | ForEach-Object { "f$_" })
    $rawHeaderRow = @(ConvertFrom-Csv -InputObject @("$headerLine") -Header $positionalNames)
    if ($rawHeaderRow.Count -gt 0) {
        foreach ($pn in $positionalNames) {
            $rawName = $rawHeaderRow[0].$pn
            # $null means the first line carries fewer fields than Import-Csv reported (a header
            # that spans lines); only a field that is present and blank is a nameless column.
            if ($null -ne $rawName -and [string]::IsNullOrWhiteSpace([string]$rawName)) {
                throw "CSV header contains an empty column name."
            }
        }
    }

    # Leading/trailing whitespace in a header is never part of the column name (BUG-073).
    $headers = @($rawHeaders | ForEach-Object { "$_".Trim() })
    foreach ($h in $headers) { if ($h -eq '') { throw "CSV header contains an empty column name." } }
    $dupHeaders = @($headers | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($dupHeaders.Count -gt 0) { throw "CSV header contains duplicate column names after trimming whitespace: $($dupHeaders -join ', ')" }
    # E2E1-020: every row binds one parameter per column and SQLite accepts at most 999 bound
    # variables per statement, so a wider file used to die on the FIRST INSERT with the provider's
    # raw 'too many SQL variables' message - by which time the table had already been created and a
    # retry in Strict/AppendOnly hit the same opaque error. Refuse the file before anything is
    # written, and name the real cause.
    $maxBoundParameters = 999
    if ($headers.Count -gt $maxBoundParameters) {
        throw "CSV has $($headers.Count) columns; SQLite binds at most $maxBoundParameters parameters per statement, so rows from this file cannot be inserted. Split it into imports of at most $maxBoundParameters columns."
    }
    if ($csv.Count -gt 0 -and (Compare-Object -ReferenceObject $rawHeaders -DifferenceObject $headers -SyncWindow 0 -CaseSensitive)) {
        # Re-read with the trimmed names as the header (the first line is then a data row to skip).
        $csv = @(Import-Csv -LiteralPath $CsvPath -Header $headers | Select-Object -Skip 1)
    }

    # Normalize null tokens
    foreach ($row in $csv) {
        foreach ($p in $row.PSObject.Properties.Name) {
            $val = $row.$p
            if ($IgnoreNullTokenCase) { $isNull = ($NullTokens -contains $val) } else { $isNull = ($NullTokens -ccontains $val) }
            if ($isNull) { $row.$p = $null; continue }
        }
    }

    # E2E1-002: the bool decision needs the types the table already declares, so the schema is read
    # before the rows are rewritten (it used to be read only after the table had been created).
    # Reading it here also serves the schema-mode checks and the type reconciliation below.
    $quotedTableIdent = ConvertTo-Ident $TableName
    $existing = @(Invoke-DbQuery -Database $Database -Query "PRAGMA table_info($quotedTableIdent)")
    $existingNames = @($existing | ForEach-Object { [string]$_.name })
    $declaredTypes = @{}
    foreach ($ci in $existing) { $declaredTypes[[string]$ci.name] = "$($ci.type)".ToUpperInvariant() }

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
            # E2E1-002: a column the table already stores as text (or as a typeless/BLOB column) is
            # never re-encoded. An append used to rewrite 'no' to 0 in a TEXT column that already
            # held 'yes' and 'maybe', leaving one column with two representations.
            $declaredType = $null
            if ($declaredTypes.ContainsKey($p)) { $declaredType = [string]$declaredTypes[$p] }
            if ($null -ne $declaredType -and ($declaredType -eq '' -or $declaredType -match 'CHAR|CLOB|TEXT|BLOB')) { continue }
            $isBoolColumn = $true; $seenTrue = $false; $seenFalse = $false
            foreach ($row in $csv) {
                $val = $row.$p
                if ($null -eq $val) { continue }
                if ($val -isnot [string]) { $isBoolColumn = $false; break }
                $lc = $val.ToLowerInvariant()
                if ($trueTokens -contains $lc) { $seenTrue = $true }
                elseif ($falseTokens -contains $lc) { $seenFalse = $true }
                else { $isBoolColumn = $false; break }
            }
            if (-not $isBoolColumn) { continue }
            if (-not ($seenTrue -or $seenFalse)) { continue }
            # E2E1-002: one token is no evidence of a boolean column - 'Y', 'NO' and 'true' are
            # ordinary text in a file that never shows the opposite token, and a one-row CSV or a
            # small append batch used to be enough to rewrite the whole column to 1/0. Convert only
            # when this file shows both spellings, or when the table already declares the column
            # with a numeric type (so an append into an established boolean column keeps 1/0).
            if (-not ($seenTrue -and $seenFalse) -and $null -eq $declaredType) { continue }
            foreach ($row in $csv) {
                $val = $row.$p
                if ($null -eq $val) { continue }
                if ($trueTokens -contains $val.ToLowerInvariant()) { $row.$p = 1 } else { $row.$p = 0 }
            }
        }
    }

    # When '' is not a null token it is a real value and must never land in a numeric column.
    $columnTypes = Test-ColumnTypes -Csv $csv -Headers $headers -EmptyIsText:($NullTokens -notcontains '')
    foreach ($h in $headers) { if (-not $columnTypes[$h]) { $columnTypes[$h] = 'TEXT' } }

    $quotedCols = ($headers | ForEach-Object { "$(ConvertTo-Ident $_) $($columnTypes[$_])" }) -join ", "

    # Validate the schema mode against the table as it stands. Only Relaxed creates the table;
    # Strict and AppendOnly require it to exist so a misspelled -TableName fails instead of quietly
    # creating a second table (BUG-074). These checks read the database and never write to it, so
    # they also run under -WhatIf (E2E1-004).
    if ($SchemaMode -ne 'Relaxed') {
        $exists = @(Invoke-DbQuery -Database $Database -Query "SELECT name FROM sqlite_master WHERE type='table' AND name=@t" -SqlParameters @{ t = $TableName })
        if ($exists.Count -eq 0) { throw "$SchemaMode mode: table '$TableName' does not exist." }
        if ($SchemaMode -eq 'Strict') {
            foreach ($h in $headers) { if ($existingNames -notcontains $h) { throw "Strict mode: missing column $h in $TableName" } }
        }
        else {
            # AppendOnly: no schema changes allowed; every CSV column must already exist in the table
            foreach ($h in $headers) { if ($existingNames -notcontains $h) { throw "AppendOnly mode: column $h does not exist in table $TableName" } }
        }
    }

    # Reconcile inferred types with the declared column types. SQLite stores text in an INTEGER
    # column happily, but System.Data.SQLite reads that column back by its declared type and
    # returns 0 for the text, so a narrower declared type must be widened (Relaxed) or refused.
    # Only a column the table already has can need this: a column added below is created with
    # exactly the storage type that was inferred for it.
    $rank = @{ INTEGER = 1; REAL = 2; TEXT = 3 }
    $widen = @{}
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($h in $headers) {
        $hasValue = $false
        foreach ($row in $csv) { if ($null -ne $row.$h) { $hasValue = $true; break } }
        if (-not $hasValue) { continue }
        $inferred = ($columnTypes[$h] -replace '(?i)\s+(PRIMARY\s+KEY|AUTOINCREMENT|UNIQUE)\b.*$', '').Trim().ToUpperInvariant()
        if (-not $rank.ContainsKey($inferred)) { continue }
        $info = $existing | Where-Object { $_.name -eq $h } | Select-Object -First 1
        if (-not $info) { continue }
        $declared = "$($info.type)".ToUpperInvariant()
        # SQLite affinity rules: INT -> INTEGER; CHAR/CLOB/TEXT -> TEXT; blank/BLOB -> stored as given; REAL/FLOA/DOUB and NUMERIC -> numeric
        if ($declared -match 'INT') { $declaredRank = 1 }
        elseif ($declared -match 'CHAR|CLOB|TEXT' -or $declared -eq '' -or $declared -match 'BLOB') { $declaredRank = 3 }
        else { $declaredRank = 2 }
        # E2E1-011: a column the table already declares numeric, holding CSV values that are only
        # non-canonical spellings of numbers ('10.0', '1.10' - a REAL round-trips them as '10' and
        # '1.1', so Get-CsvValueKind calls them TEXT), differs in formatting, not in type. Rewriting
        # such a column to TEXT changed every value already stored in it (and every later numeric
        # comparison, ORDER BY and SUM), while Strict and AppendOnly refused the file outright and
        # pointed at the one mode that must not be used here. Store the numbers in the numeric
        # column instead. Columns the table does not have yet are untouched by this: they are still
        # created as TEXT so a trailing zero is preserved exactly.
        $effective = $inferred
        if ($inferred -eq 'TEXT' -and $declaredRank -lt 3) {
            $allNumeric = $true
            foreach ($row in $csv) {
                $val = $row.$h
                if ($null -eq $val) { continue }
                $text = "$val"
                $kind = Get-CsvValueKind -Value $text
                if ($kind -eq 'INTEGER' -or $kind -eq 'REAL') { continue }
                if ($text -match '^-?\d+\.\d+$') {
                    $parsed = [double]0
                    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, $invariant, [ref]$parsed) -and -not [double]::IsInfinity($parsed)) { continue }
                }
                $allNumeric = $false
                break
            }
            if ($allNumeric) { $effective = 'REAL' }
        }
        if ($rank[$effective] -gt $declaredRank) {
            if ($SchemaMode -eq 'Relaxed') { $widen[$h] = $effective }
            else { throw "$SchemaMode mode: column '$h' in table '$TableName' is declared $($info.type) but the CSV contains $effective values; use -SchemaMode Relaxed to widen the column" }
        }
    }

    # E2E1-004: one ShouldProcess gate for the whole import. Everything above only reads, so -WhatIf
    # (or an inherited $WhatIfPreference) now previews the import - including the schema-mode and
    # column-type checks - instead of writing every row while the helpers skipped themselves.
    if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess($Database, "Import '$CsvPath' into table '$TableName'")) { return $headers }

    # The widening rebuild stays outside the import's own transaction: it manages its own SAVEPOINT,
    # and when the caller already holds a transaction a failure inside it must leave that
    # transaction intact (E2E1-001). It only ever touches columns that already exist.
    if ($widen.Count -gt 0) {
        # E2E1-011: changing the declared type of an existing column rewrites every value already
        # stored in it, so say so instead of leaving only a DEBUG log line behind.
        foreach ($wcol in @($widen.Keys)) {
            $wasType = [string]$declaredTypes[$wcol]
            if ($wasType -eq '') { $wasType = '(no type)' }
            Write-Warning "Import-CsvToSqlite: column '$wcol' of table '$TableName' is changed from $wasType to $($widen[$wcol]); the values already stored in it are rewritten."
        }
        Update-DbColumnType -Database $Database -Table $TableName -ColumnTypes $widen
    }

    # E2E1-012: CREATE TABLE and ALTER TABLE ADD COLUMN now run inside the same transaction as the
    # inserts. A failed import used to leave a table or a column behind that no row ever populated,
    # so the next Strict/AppendOnly import passed schema checks it should have failed.
    $tx = Start-DbTransaction -Database $Database -WhatIf:$false -Confirm:$false
    try {
        if ($SchemaMode -eq 'Relaxed') {
            if (-not [string]::IsNullOrWhiteSpace($quotedCols)) {
                $createQuery = "CREATE TABLE IF NOT EXISTS $quotedTableIdent ($quotedCols)"
                Write-DbLog DEBUG "Creating table with query: $createQuery"
                Invoke-DbQuery -Database $Database -Query $createQuery -NonQuery -Transaction $tx | Out-Null
            }
            # Re-read: the table may have just been created, and a widening rebuild replaces it.
            $existing = @(Invoke-DbQuery -Database $Database -Query "PRAGMA table_info($quotedTableIdent)")
            $existingNames = @($existing | ForEach-Object { [string]$_.name })
            $added = $false
            $needUnique = New-Object System.Collections.Generic.List[string]
            foreach ($h in $headers) {
                if ($existingNames -notcontains $h) {
                    # ALTER TABLE ADD COLUMN cannot add PRIMARY KEY / AUTOINCREMENT / UNIQUE columns;
                    # add the bare storage type instead (e.g. 'id' becomes plain INTEGER).
                    $fullType = [string]$columnTypes[$h]
                    $addType = $fullType -replace '(?i)\s+(PRIMARY\s+KEY|AUTOINCREMENT|UNIQUE)\b.*$', ''
                    if ([string]::IsNullOrWhiteSpace($addType)) { $addType = 'TEXT' }
                    $sql = "ALTER TABLE $quotedTableIdent ADD COLUMN $(ConvertTo-Ident $h) $addType"
                    Invoke-DbQuery -Database $Database -Query $sql -NonQuery -Transaction $tx | Out-Null
                    $added = $true
                    # E2E1-009: the uniqueness the inferred type asked for cannot be part of the
                    # ALTER, so it is created as a unique index instead. Without it an 'id' column
                    # that arrives on a later import accepted duplicate ids silently, and the
                    # documented UNIQUE failure on a repeated import never happened.
                    if ($fullType -match '(?i)\b(PRIMARY\s+KEY|UNIQUE)\b') { [void]$needUnique.Add($h) }
                }
            }
            if ($added) {
                # Verify the columns really exist before inserting (on Windows PowerShell 5.1 the
                # PSSQLite fallback reports SQL errors non-terminatingly).
                $existing = @(Invoke-DbQuery -Database $Database -Query "PRAGMA table_info($quotedTableIdent)")
                $existingNames = @($existing | ForEach-Object { [string]$_.name })
                foreach ($h in $headers) { if ($existingNames -notcontains $h) { throw "Relaxed mode: failed to add column $h to $TableName" } }
            }
            foreach ($u in $needUnique) { Enable-UniqueIndex -Database $Database -Table $TableName -Columns @($u) | Out-Null }
        }

        # Blank ids in an INTEGER PRIMARY KEY column would be auto-numbered from the current maximum
        # and collide with explicit ids later in the same file; number them past every known id first.
        $idHeader = $headers | Where-Object { $_ -eq 'id' } | Select-Object -First 1
        if ($idHeader) {
            $idInfo = $existing | Where-Object { $_.name -eq $idHeader } | Select-Object -First 1
            if ($idInfo -and [int]$idInfo.pk -eq 1 -and "$($idInfo.type)" -match '(?i)INT') {
                $blankRows = @($csv | Where-Object { $null -eq $_.$idHeader })
                $explicitIds = @($csv | Where-Object { $null -ne $_.$idHeader } | ForEach-Object { [long]$_.$idHeader })
                if ($blankRows.Count -gt 0 -and $explicitIds.Count -gt 0) {
                    $next = ($explicitIds | Measure-Object -Maximum).Maximum
                    $maxRow = Invoke-DbQuery -Database $Database -Query "SELECT MAX($(ConvertTo-Ident $idHeader)) AS m FROM $quotedTableIdent" -Transaction $tx | Select-Object -First 1
                    if ($maxRow -and $null -ne $maxRow.m -and $maxRow.m -isnot [System.DBNull] -and [long]$maxRow.m -gt $next) { $next = [long]$maxRow.m }
                    $hasSeq = Invoke-DbQuery -Database $Database -Query "SELECT name FROM sqlite_master WHERE type='table' AND name='sqlite_sequence'" -Transaction $tx
                    if ($hasSeq) {
                        $seqRow = Invoke-DbQuery -Database $Database -Query "SELECT seq FROM sqlite_sequence WHERE name=@t" -SqlParameters @{ t = $TableName } -Transaction $tx | Select-Object -First 1
                        if ($seqRow -and $null -ne $seqRow.seq -and $seqRow.seq -isnot [System.DBNull] -and [long]$seqRow.seq -gt $next) { $next = [long]$seqRow.seq }
                    }
                    foreach ($row in $blankRows) { $next = [long]$next + 1; $row.$idHeader = $next }
                }
            }
        }

        # Insert data
        $count = 0
        foreach ($row in $csv) {
            $keys = $row.PSObject.Properties.Name
            $columns = (($keys | ForEach-Object { ConvertTo-Ident $_ })) -join ", "
            # Positional parameter names (@p0, @p1, ...) cannot collide the way sanitized
            # header text did ('a b', 'a_b' and 'a-b' all became @a_b).
            $paramNames = ConvertTo-ParamMap -Columns $keys
            $placeholders = (($keys | ForEach-Object { "@$($paramNames[$_])" })) -join ", "
            $query = "INSERT INTO $quotedTableIdent ($columns) VALUES ($placeholders)"
            $params = @{}
            foreach ($k in $keys) {
                $paramName = $paramNames[$k]
                $value = $row.$k
                # BUG-E2E1-013: SQLite text parameters cannot carry an embedded NUL (the value
                # would be stored truncated at the NUL). Invoke-DbQuery guards this too, but it
                # only knows the positional parameter name, so name the column and row here.
                if ($value -is [string] -and $value.IndexOf([char]0) -ge 0) {
                    throw "Import-CsvToSqlite: column '$k' in row $($count + 1) contains a NUL character (U+0000), which SQLite cannot store as text. Clean the CSV before importing."
                }
                $params[$paramName] = $value
            }
            [void](Invoke-DbQuery -Database $Database -Query $query -SqlParameters $params -NonQuery -Transaction $tx)
            $count++
            if ($BatchSize -gt 0 -and ($count % $BatchSize) -eq 0) {
                $pct = [int][math]::Min(100, ($count / [double]$total) * 100)
                Write-Progress -Activity "Importing $TableName" -Status "$count / $total" -PercentComplete $pct
            }
        }
        Complete-DbTransaction -Database $Database -Transaction $tx
    }
    catch { Undo-DbTransaction -Database $Database -Transaction $tx; throw }

    # E2E1-004: the catalog is part of this operation, not something the caller can skip on its own.
    Update-DbCatalog -Database $Database -SourceCsvPath $CsvPath -Table $TableName -WhatIf:$false -Confirm:$false
    return $headers
}
