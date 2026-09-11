function Invoke-DbQuery {
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$SqlParameters,
        [switch]$Scalar,
        [switch]$NonQuery,
        [switch]$AsDataTable,
        [System.Data.SQLite.SQLiteTransaction]$Transaction
    )

    # BUG-047: log parameter names only (never bound values such as row data or
    # credentials), and build the string only when DEBUG logging is enabled.
    if ($script:DbLogLevel -eq 'DEBUG') {
        $paramNames = ''
        if ($SqlParameters) { $paramNames = (@($SqlParameters.Keys | ForEach-Object { [string]$_ }) -join ', ') }
        Write-DbLog DEBUG "SQL: $Query | ParamNames: $paramNames"
    }

    # BUG-E2E1-013: both the System.Data.SQLite path and the PSSQLite fallback marshal a string
    # parameter as a NUL-terminated UTF-8 buffer, so a value containing U+0000 is stored truncated
    # at the NUL with no error or warning. Fail loudly rather than write a corrupted row.
    if ($SqlParameters) {
        foreach ($k in @($SqlParameters.Keys)) {
            $pv = $SqlParameters[$k]
            if ($pv -is [char]) { $pv = [string]$pv }
            if ($pv -is [string]) {
                $nulAt = $pv.IndexOf([char]0)
                if ($nulAt -ge 0) {
                    throw "Invoke-DbQuery: parameter '$k' contains a NUL character (U+0000) at index $nulAt. SQLite text parameters cannot carry an embedded NUL - the value would be stored silently truncated. Remove the NUL, or pass the value as a byte array to store it as a BLOB."
                }
            }
        }
    }

    $conn = Get-DbConnection -Database $Database
    if ($conn -and $conn.State -eq 'Open') {
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $Query
        if ($Transaction) { $cmd.Transaction = $Transaction }
        if ($SqlParameters) {
            foreach ($k in $SqlParameters.Keys) {
                $p = $cmd.CreateParameter(); $p.ParameterName = "@$k"; $p.Value = $SqlParameters[$k]; [void]$cmd.Parameters.Add($p)
            }
        }
        try {
            if ($Scalar) {
                # BUG-E2E1-019: ExecuteScalar returns [System.DBNull]::Value when the selected cell
                # is SQL NULL and $null only when there are no rows at all. Map DBNull to $null so
                # -Scalar has a single representation of "nothing" and matches the row path
                # (ConvertFrom-DbDataTable) and the PSSQLite fallback.
                $scalarValue = $cmd.ExecuteScalar()
                if ($scalarValue -is [System.DBNull]) { return $null }
                return $scalarValue
            }
            elseif ($NonQuery) { return $cmd.ExecuteNonQuery() }
            else {
                $dt = New-Object System.Data.DataTable
                $da = New-Object System.Data.SQLite.SQLiteDataAdapter($cmd); [void]$da.Fill($dt)
                # the comma keeps the DataTable intact; a bare DataTable unrolls into DataRows on output
                if ($AsDataTable) { return , $dt }
                # BUG-026: project only the result columns (no DataRow members such as
                # RowState/Table/ItemArray) and map DBNull to $null, matching the PSSQLite path.
                return (ConvertFrom-DbDataTable -DataTable $dt)
            }
        }
    catch { Write-DbLog ERROR "Invoke-DbQuery error" $_.Exception; throw }
        finally { $cmd.Dispose() }
    }
    else {
        # Fallback path via PSSQLite
        # BUG-072: PSSQLite concatenates the path into its connection string, so ';' cannot be handled here
        if ($Database -match ';') { throw "Invoke-DbQuery: database path '$Database' contains ';' which is not supported by the PSSQLite fallback path (System.Data.SQLite is not available)." }
        Enable-ForeignKeysPragma -Database $Database
        # BUG-008: foreign_keys is a per-connection pragma and Invoke-SqliteQuery opens a new
        # connection per call, so it must be enabled inside every statement batch. The pragma
        # produces no result set, so it does not change what the SELECT/-Scalar branches return.
        $fkPrefix = "PRAGMA foreign_keys = ON;`n"
        # BUG-009: PSSQLite reports SQL failures with Write-Error under its own scope's
        # $ErrorActionPreference; -ErrorAction Stop makes them terminating so the catch rethrows.
        try {
            if ($Scalar) {
                # BUG-007: @() so a one-row result (a bare PSCustomObject on 5.1, where .Count is $null) is counted
                $q = @(Invoke-SqliteQuery -DataSource $Database -Query ($fkPrefix + $Query) -SqlParameters $SqlParameters -ErrorAction Stop)
                if ($q.Count -gt 0) {
                    $firstProp = $q[0].PSObject.Properties | Select-Object -First 1
                    # BUG-E2E1-019: normalise DBNull to $null here too, so both paths agree.
                    if ($firstProp) {
                        $scalarValue = $firstProp.Value
                        if ($scalarValue -is [System.DBNull]) { return $null }
                        return $scalarValue
                    }
                    else { return $null }
                }
                else { return $null }
            }
            elseif ($NonQuery) {
                # BUG-026: return the affected-row count like the direct path does. PSSQLite opens a
                # new connection per call, so changes() must run in the same statement batch.
                # The terminator goes on its own line so a trailing same-line "-- comment" in
                # $Query cannot swallow it; SQLite skips the empty statement when $Query already ends with ';'.
                $batch = $fkPrefix + $Query.TrimEnd() + "`n;`nSELECT changes() AS affected;"
                $q = @(Invoke-SqliteQuery -DataSource $Database -Query $batch -SqlParameters $SqlParameters -ErrorAction Stop)
                if ($q.Count -gt 0 -and $null -ne $q[0].affected) { return [int]$q[0].affected } else { return 0 }
            }
            elseif ($AsDataTable) {
                # BUG-068: honor -AsDataTable on the fallback path too. PSSQLite's -As DataTable
                # emits the table collection, which PowerShell unrolls into DataRows, so ask for
                # the DataSet (not enumerable) and return its first table with the unary comma.
                $ds = Invoke-SqliteQuery -DataSource $Database -Query ($fkPrefix + $Query) -SqlParameters $SqlParameters -As DataSet -ErrorAction Stop
                if ($ds -and $ds.Tables.Count -gt 0) { return , $ds.Tables[0] }
                return , (New-Object System.Data.DataTable)
            }
            else {
                return Invoke-SqliteQuery -DataSource $Database -Query ($fkPrefix + $Query) -SqlParameters $SqlParameters -ErrorAction Stop
            }
        }
        catch { 
            Write-DbLog ERROR "Invoke-DbQuery (PSSQLite) error: Query='$Query'" $_.Exception
            throw 
        }
    }
}
