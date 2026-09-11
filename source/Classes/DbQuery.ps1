class DbQuery {
    [string]$Database; [string]$From
    [System.Collections.ArrayList]$Joins = [System.Collections.ArrayList]::new()
    [System.Collections.ArrayList]$Selects = [System.Collections.ArrayList]::new()
    [System.Collections.ArrayList]$Wheres = [System.Collections.ArrayList]::new()
    # Backing fields are named differently from the fluent methods: a property with the same name as a method
    # shadows the method in PowerShell classes (BASE-06), so $q.OrderBy('x') used to fail.
    [hashtable]$Params = @{}; [string]$OrderByExpr; [int]$LimitValue = -1; [int]$OffsetValue = -1

    DbQuery([string]$database, [string]$from) { $this.AssertTableRef($from, 'From'); $this.Database = $database; $this.From = $from }

    [DbQuery]Select([string[]]$Cols) { if ($Cols) { foreach ($c in $Cols) { [void]$this.Selects.Add($c) } }; return $this }
    [DbQuery]Where([string]$Clause, [hashtable]$Params) {
        if ($Clause) { [void]$this.Wheres.Add($Clause) }
        if ($Params) { foreach ($k in $Params.Keys) { if ($this.Params.ContainsKey($k)) { throw "Duplicate parameter key '$k' in DbQuery.Where()" }; $this.Params[$k] = $Params[$k] } }
        return $this
    }
    [DbQuery]OrderBy([string]$Expr) { $this.OrderByExpr = $Expr; return $this }
    [DbQuery]Limit([int]$n) { $this.LimitValue = $n; return $this }
    [DbQuery]Offset([int]$n) { $this.OffsetValue = $n; return $this }

    # Splits a table reference ('t', '"my t"', 't x', 't AS x') into its base name (group 1) and optional alias (group 2).
    hidden static [string]$TableRefPattern = '^\s*("(?:[^"]|"")+"|[^\s"]+)(?:\s+(?:[Aa][Ss]\s+)?("(?:[^"]|"")+"|[^\s"]+))?\s*$'
    hidden [string]GetBaseTable([string]$t) {
        if ($t -match [DbQuery]::TableRefPattern) { return ($Matches[1].Trim('"') -replace '""', '"') }
        return $t
    }
    # Qualifier to prefix column names with: the alias when one is given, otherwise the table name as written (BUG-021).
    hidden [string]GetQualifier([string]$t) {
        if ($t -match [DbQuery]::TableRefPattern) { if ($Matches[2]) { return $Matches[2] } return $Matches[1] }
        return $t
    }
    # Qualifier for a '<table>.*' result column. Like GetQualifier, except that a schema prefix is dropped:
    # SQLite's result-column grammar is <table-name>.* , so 'main.assets.*' is a syntax error while 'assets.*'
    # is accepted for 'FROM main.assets' (E2E1-005).
    hidden [string]GetStarQualifier([string]$t) {
        if ($t -match [DbQuery]::TableRefPattern) {
            if ($Matches[2]) { return $Matches[2] }
            $base = $Matches[1]
            if (-not $base.StartsWith('"') -and $base.Contains('.')) { return $base.Substring($base.LastIndexOf('.') + 1) }
            return $base
        }
        return $t
    }
    hidden [string]QuoteIdent([string]$n) { return ('"' + ($n -replace '"', '""') + '"') }
    # From and Join table references are identifiers, not SQL fragments (BUG-029). They are interpolated raw so an
    # alias can be kept as written, so an unquoted name or alias may only contain word characters and dots; anything
    # else ('a; DROP TABLE b', 'a--', 'a /* x */') is rejected before it can reach the driver, which runs
    # multi-statement text. A dash is never valid in a raw identifier ('a-b' is a subtraction, 'a--' starts a comment
    # that swallows ON/WHERE/ORDER BY/LIMIT). A double-quoted name may contain any character, dashes included.
    # Select/Where/OrderBy/On stay raw SQL by design.
    hidden static [string]$IdentTokenPattern = '^[\w.]+$'
    hidden [void]AssertTableRef([string]$t, [string]$what) {
        if ([string]::IsNullOrWhiteSpace($t)) { throw "Invalid $what table reference: value is null or empty" }
        if ($t -notmatch [DbQuery]::TableRefPattern) { throw "Invalid $what table reference '$t': expected <table> or <table> [AS] <alias>" }
        foreach ($tok in @($Matches[1], $Matches[2])) {
            if ($tok -and -not $tok.StartsWith('"') -and $tok -notmatch [DbQuery]::IdentTokenPattern) {
                throw "Invalid $what table reference '$t': '$tok' contains illegal characters"
            }
        }
    }
    # Every clause is parenthesised so an OR inside one Where() cannot escape the other filters (BUG-020).
    hidden [string]GetWhereSql() {
        $parts = @(); foreach ($w in $this.Wheres) { $parts += "($w)" }
        return ($parts -join ' AND ')
    }
    hidden [string]GetTailSql() {
        $sql = ''
        if ($this.OrderByExpr) { $sql += " ORDER BY $($this.OrderByExpr)" }
        if ($this.LimitValue -gt -1) { $sql += " LIMIT $($this.LimitValue)" }
        if ($this.OffsetValue -gt -1) { $sql += " OFFSET $($this.OffsetValue)" }
        return $sql
    }
    # PowerShell ignores default values on class method parameters, so the README's Join(<table>, <on>) form needs
    # its own overload (BUG-065). Join(<table>) uses the catalog relationship ('Auto').
    [DbQuery]Join([string]$Table) { return $this.Join($Table, 'Auto', 'Inner', '') }
    [DbQuery]Join([string]$Table, [string]$On) { return $this.Join($Table, $On, 'Inner', '') }
    [DbQuery]Join([string]$Table, [string]$On, [string]$Type) { return $this.Join($Table, $On, $Type, '') }
    # E2E1-015: $ForeignKey names the foreign-key column an 'Auto' join must use when the catalog holds more than
    # one relationship between the same pair of tables (tickets.created_by and tickets.assigned_to both pointing
    # at users, for example). Without it such a join is ambiguous and throws instead of picking a side silently.
    [DbQuery]Join([string]$Table, [string]$On, [string]$Type, [string]$ForeignKey) {
        if ($Type -notin @('Inner', 'Left', 'Right', 'Full')) { throw "Invalid join type '$Type'." }
        $this.AssertTableRef($Table, 'Join')
        if ($ForeignKey -and $On -ne 'Auto') { throw "The ForeignKey argument of Join() applies to an 'Auto' join only; the ON clause '$On' already names the columns." }
        $spec = [DbJoinSpec]::new(); $spec.Type = $Type; $spec.Table = $Table
        if ($On -eq 'Auto') {
            $baseA = $this.GetBaseTable($this.From); $baseB = $this.GetBaseTable($Table)
            $qualA = $this.GetQualifier($this.From); $qualB = $this.GetQualifier($Table)
            # No LIMIT 1: every candidate is fetched so an ambiguous catalog can be reported (E2E1-015).
            $q = @"
SELECT table_name, column_name, ref_table, ref_column, status, confidence FROM __fks__
WHERE (table_name=@a AND ref_table=@b) OR (table_name=@b AND ref_table=@a)
ORDER BY status='confirmed' DESC, confidence DESC, table_name, column_name
"@
            # @() guards a one-row result on Windows PowerShell 5.1, where a lone PSCustomObject has no .Count
            $rel = @(Invoke-DbQuery -Database $this.Database -Query $q -SqlParameters @{ a = $baseA; b = $baseB })
            if ($ForeignKey) {
                $rel = @($rel | Where-Object { $_.column_name -eq $ForeignKey })
                if ($rel.Count -eq 0) { throw "No relationship found between $baseA and $baseB on foreign key column '$ForeignKey' for Auto join." }
            }
            if ($rel.Count -eq 0) { throw "No relationship found between $baseA and $baseB for Auto join." }
            $r = $rel[0]
            if (-not $ForeignKey -and $rel.Count -gt 1) {
                # Only candidates of the same rank as the best one are ambiguous; a weaker row is a deterministic loser.
                $names = @()
                foreach ($c in $rel) {
                    if (([string]$c.status -eq [string]$r.status) -and ([string]$c.confidence -eq [string]$r.confidence)) {
                        $names += "$($c.table_name).$($c.column_name) = $($c.ref_table).$($c.ref_column)"
                    }
                }
                $names = @($names | Sort-Object -Unique)
                if ($names.Count -gt 1) {
                    throw "Auto join between $baseA and $baseB is ambiguous: $($names.Count) relationships of equal rank match ($($names -join '; ')). Pass an explicit ON clause, or name the foreign-key column with Join(<table>, 'Auto', <type>, <column>)."
                }
            }
            if ($r.table_name -eq $baseB -and $r.ref_table -eq $baseA) { $spec.On = "$qualB.$($this.QuoteIdent($r.column_name)) = $qualA.$($this.QuoteIdent($r.ref_column))" }
            else { $spec.On = "$qualA.$($this.QuoteIdent($r.column_name)) = $qualB.$($this.QuoteIdent($r.ref_column))" }
        }
        else { $spec.On = $On }
        [void]$this.Joins.Add($spec); return $this
    }

    [object[]]Run() {
        $selectClause = if ($this.Selects.Count -gt 0) { ($this.Selects -join ', ') } else { '*' }
        $hasRightOrFull = $false
        foreach ($j in $this.Joins) { if ($j.Type -in @('Right','Full')) { $hasRightOrFull = $true } }

        if (-not $hasRightOrFull) {
            $sql = "SELECT $selectClause FROM $($this.From)"
            foreach ($j in $this.Joins) {
                $jt = switch ($j.Type) { 'Left' { 'LEFT JOIN' } default { 'INNER JOIN' } }
                $sql += " $jt $($j.Table) ON $($j.On)"
            }
            if ($this.Wheres.Count -gt 0) { $sql += " WHERE " + $this.GetWhereSql() }
            $sql += $this.GetTailSql()
            # E2E1-017: always hand back an array. An empty pipeline result would otherwise leave the method with
            # $null, while every record finder returns an empty array, so @($q.Run()).Count read 1 instead of 0.
            $rows = @(Invoke-DbQuery -Database $this.Database -Query $sql -SqlParameters $this.Params)
            return $rows
        }
        else {
            if ($this.Joins.Count -ne 1) { throw "RIGHT/FULL join emulation currently supports a single join only." }
            $j = $this.Joins[0]
            # E2E1-005: a bare '*' expands in FROM order, and the emulation swaps the tables round, so the two
            # halves of the UNION ALL (which matches columns by position) would not line up and a Right join
            # would return its columns in join-table-first order. Project both sides explicitly and in From order.
            if ($this.Selects.Count -eq 0) {
                $selectClause = "$($this.GetStarQualifier($this.From)).*, $($this.GetStarQualifier($j.Table)).*"
            }
            $whereSql = $this.GetWhereSql()
            if ($j.Type -eq 'Right') {
                # Emulate RIGHT JOIN by swapping tables into a LEFT JOIN
                $sql = "SELECT $selectClause FROM $($j.Table) LEFT JOIN $($this.From) ON $($j.On)"
                if ($whereSql) { $sql += " WHERE $whereSql" }
            }
            elseif ($j.Type -eq 'Full') {
                # Emulate FULL OUTER JOIN as LEFT JOIN UNION ALL the unmatched rows of the swapped LEFT JOIN (BUG-028).
                # UNION ALL keeps genuine duplicate rows; the rowid test keeps only rows of the join table that have
                # no partner in the From table, so nothing is counted twice. The user filter applies to both halves.
                # The rowid test only means "no partner row" for a rowid table, so the From source is checked first
                # (E2E1-016): a view has no rowid and the two supported SQLite engines then disagree silently.
                $this.AssertFullJoinSource()
                $left = "SELECT $selectClause FROM $($this.From) LEFT JOIN $($j.Table) ON $($j.On)"
                if ($whereSql) { $left += " WHERE $whereSql" }
                $right = "SELECT $selectClause FROM $($j.Table) LEFT JOIN $($this.From) ON $($j.On) WHERE $($this.GetQualifier($this.From)).rowid IS NULL"
                if ($whereSql) { $right += " AND $whereSql" }
                $sql = "$left UNION ALL $right"
            }
            else { throw "Unexpected join type for emulation: $($j.Type)" }

            $sql += $this.GetTailSql()
            $rows = @(Invoke-DbQuery -Database $this.Database -Query $sql -SqlParameters $this.Params)
            return $rows
        }
    }

    # E2E1-016: the FULL emulation identifies unmatched rows with '<From>.rowid IS NULL'. A view or a WITHOUT ROWID
    # table has no rowid: SQLite 3.8.8.3 (Windows PowerShell 5.1) then drops the whole second half while the newer
    # engine used on PowerShell 7 treats the rowid as NULL for every row and duplicates the left side. Reject the
    # unsupported source with a clear message instead of returning a different wrong answer per host.
    hidden [void]AssertFullJoinSource() {
        if (-not ($this.From -match [DbQuery]::TableRefPattern)) { return }
        $base = $Matches[1]
        # A schema-qualified reference ('other.t') is not looked up: sqlite_master lists the objects of one schema
        # only, so the bare name could match an unrelated object in main. Leave those to SQLite.
        if (-not $base.StartsWith('"') -and $base.Contains('.')) { return }
        $name = $this.GetBaseTable($this.From)
        $meta = @(Invoke-DbQuery -Database $this.Database -Query 'SELECT type, sql FROM sqlite_master WHERE name = @n' -SqlParameters @{ n = $name })
        if ($meta.Count -eq 0) { return }
        $type = [string]$meta[0].type
        $ddl = [string]$meta[0].sql
        if ($type -and $type -ne 'table') {
            throw "A Full join requires a rowid table as its From source; '$name' is a $type. Select from the base table, or use an Inner/Left/Right join."
        }
        # Anchored at the end of the stored DDL, where the clause always sits, so a string literal or a column
        # named like the clause cannot trigger a false rejection. A missed exotic form still fails loudly with
        # SQLite's own "no such column: <table>.rowid".
        if ($ddl -match '(?i)\bWITHOUT\s+ROWID\s*;?\s*$') {
            throw "A Full join requires a rowid table as its From source; '$name' is declared WITHOUT ROWID. Swap the tables and use a Right join, or use an Inner/Left join."
        }
    }
}
