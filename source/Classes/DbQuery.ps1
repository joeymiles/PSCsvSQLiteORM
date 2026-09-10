class DbQuery {
    [string]$Database; [string]$From
    [System.Collections.ArrayList]$Joins = [System.Collections.ArrayList]::new()
    [System.Collections.ArrayList]$Selects = [System.Collections.ArrayList]::new()
    [System.Collections.ArrayList]$Wheres = [System.Collections.ArrayList]::new()
    # Backing fields are named differently from the fluent methods: a property with the same name as a method
    # shadows the method in PowerShell classes (BASE-06), so $q.OrderBy('x') used to fail.
    [hashtable]$Params = @{}; [string]$OrderByExpr; [int]$LimitValue = -1; [int]$OffsetValue = -1

    DbQuery([string]$database, [string]$from) { $this.Database = $database; $this.From = $from }

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
    hidden [string]QuoteIdent([string]$n) { return ('"' + ($n -replace '"', '""') + '"') }
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
    [DbQuery]Join([string]$Table, [string]$On, [string]$Type = 'Inner') {
        if ($Type -notin @('Inner', 'Left', 'Right', 'Full')) { throw "Invalid join type '$Type'." }
        $spec = [DbJoinSpec]::new(); $spec.Type = $Type; $spec.Table = $Table
        if ($On -eq 'Auto') {
            $baseA = $this.GetBaseTable($this.From); $baseB = $this.GetBaseTable($Table)
            $qualA = $this.GetQualifier($this.From); $qualB = $this.GetQualifier($Table)
            $q = @"
SELECT * FROM __fks__
WHERE (table_name=@a AND ref_table=@b) OR (table_name=@b AND ref_table=@a)
ORDER BY status='confirmed' DESC, confidence DESC
LIMIT 1
"@
            # @() guards a one-row result on Windows PowerShell 5.1, where a lone PSCustomObject has no .Count
            $rel = @(Invoke-DbQuery -Database $this.Database -Query $q -SqlParameters @{ a = $baseA; b = $baseB })
            if ($rel.Count -gt 0) {
                $r = $rel[0]
                if ($r.table_name -eq $baseB -and $r.ref_table -eq $baseA) { $spec.On = "$qualB.$($this.QuoteIdent($r.column_name)) = $qualA.$($this.QuoteIdent($r.ref_column))" }
                else { $spec.On = "$qualA.$($this.QuoteIdent($r.column_name)) = $qualB.$($this.QuoteIdent($r.ref_column))" }
            }
            else { throw "No relationship found between $baseA and $baseB for Auto join." }
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
            return Invoke-DbQuery -Database $this.Database -Query $sql -SqlParameters $this.Params
        }
        else {
            if ($this.Joins.Count -ne 1) { throw "RIGHT/FULL join emulation currently supports a single join only." }
            $j = $this.Joins[0]
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
                $left = "SELECT $selectClause FROM $($this.From) LEFT JOIN $($j.Table) ON $($j.On)"
                if ($whereSql) { $left += " WHERE $whereSql" }
                $right = "SELECT $selectClause FROM $($j.Table) LEFT JOIN $($this.From) ON $($j.On) WHERE $($this.GetQualifier($this.From)).rowid IS NULL"
                if ($whereSql) { $right += " AND $whereSql" }
                $sql = "$left UNION ALL $right"
            }
            else { throw "Unexpected join type for emulation: $($j.Type)" }

            $sql += $this.GetTailSql()
            return Invoke-DbQuery -Database $this.Database -Query $sql -SqlParameters $this.Params
        }
    }
}
