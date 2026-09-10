class DbQuery {
    [string]$Database; [string]$From
    [System.Collections.ArrayList]$Joins = [System.Collections.ArrayList]::new()
    [System.Collections.ArrayList]$Selects = [System.Collections.ArrayList]::new()
    [System.Collections.ArrayList]$Wheres = [System.Collections.ArrayList]::new()
    [hashtable]$Params = @{}; [string]$OrderBy; [int]$Limit = -1; [int]$Offset = -1

    DbQuery([string]$database, [string]$from) { $this.Database = $database; $this.From = $from }

    [DbQuery]Select([string[]]$Cols) { if ($Cols) { foreach ($c in $Cols) { [void]$this.Selects.Add($c) } }; return $this }
    [DbQuery]Where([string]$Clause, [hashtable]$Params) {
        if ($Clause) { [void]$this.Wheres.Add($Clause) }
        if ($Params) { foreach ($k in $Params.Keys) { if ($this.Params.ContainsKey($k)) { throw "Duplicate parameter key '$k' in DbQuery.Where()" }; $this.Params[$k] = $Params[$k] } }
        return $this
    }
    [DbQuery]OrderBy([string]$Expr) { $this.OrderBy = $Expr; return $this }
    [DbQuery]Limit([int]$n) { $this.Limit = $n; return $this }
    [DbQuery]Offset([int]$n) { $this.Offset = $n; return $this }

    hidden [string]GetBaseTable([string]$t) { if ($t -match '^\s*([^\s]+)') { return $Matches[1].Trim('"') } return $t }
    [DbQuery]Join([string]$Table, [string]$On, [string]$Type = 'Inner') {
        if ($Type -notin @('Inner', 'Left', 'Right', 'Full')) { throw "Invalid join type '$Type'." }
        $spec = [DbJoinSpec]::new(); $spec.Type = $Type; $spec.Table = $Table
        if ($On -eq 'Auto') {
            $baseA = $this.GetBaseTable($this.From); $baseB = $this.GetBaseTable($Table)
            $q = @"
SELECT * FROM __fks__
WHERE (table_name=@a AND ref_table=@b) OR (table_name=@b AND ref_table=@a)
ORDER BY status='confirmed' DESC, confidence DESC
LIMIT 1
"@
            # BUG-007: @() so a single __fks__ row (bare PSCustomObject on 5.1, .Count is $null) is counted
            $rel = @(Invoke-DbQuery -Database $this.Database -Query $q -SqlParameters @{ a = $baseA; b = $baseB })
            if ($rel.Count -gt 0) {
                $r = $rel[0]
                if ($r.table_name -eq $baseB -and $r.ref_table -eq $baseA) { $spec.On = "$Table.`"$($r.column_name)`" = $($this.From).`"$($r.ref_column)`"" }
                else { $spec.On = "$($this.From).`"$($r.column_name)`" = $Table.`"$($r.ref_column)`"" }
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
            if ($this.Wheres.Count -gt 0) { $sql += " WHERE " + ($this.Wheres -join " AND ") }
            if ($this.OrderBy) { $sql += " ORDER BY $($this.OrderBy)" }
            if ($this.Limit -gt -1) { $sql += " LIMIT $($this.Limit)" }
            if ($this.Offset -gt -1) { $sql += " OFFSET $($this.Offset)" }
            return Invoke-DbQuery -Database $this.Database -Query $sql -SqlParameters $this.Params
        }
        else {
            if ($this.Joins.Count -ne 1) { throw "RIGHT/FULL join emulation currently supports a single join only." }
            $j = $this.Joins[0]
            if ($j.Type -eq 'Right') {
                # Emulate RIGHT JOIN by swapping tables into a LEFT JOIN
                $sql = "SELECT $selectClause FROM $($j.Table) LEFT JOIN $($this.From) ON $($j.On)"
            }
            elseif ($j.Type -eq 'Full') {
                # Emulate FULL OUTER JOIN via UNION of two LEFT JOINs
                $left = "SELECT $selectClause FROM $($this.From) LEFT JOIN $($j.Table) ON $($j.On)"
                $right = "SELECT $selectClause FROM $($j.Table) LEFT JOIN $($this.From) ON $($j.On)"
                $sql = "$left UNION $right"
            }
            else { throw "Unexpected join type for emulation: $($j.Type)" }

            if ($this.Wheres.Count -gt 0) { $sql = "$sql WHERE " + ($this.Wheres -join " AND ") }
            if ($this.OrderBy) { $sql += " ORDER BY $($this.OrderBy)" }
            if ($this.Limit -gt -1) { $sql += " LIMIT $($this.Limit)" }
            if ($this.Offset -gt -1) { $sql += " OFFSET $($this.Offset)" }
            return Invoke-DbQuery -Database $this.Database -Query $sql -SqlParameters $this.Params
        }
    }
}
