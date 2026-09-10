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

    $paramPairs = ''
    if ($SqlParameters) { $paramPairs = (($SqlParameters.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ') }
    Write-DbLog DEBUG "SQL: $Query | Params: $paramPairs"

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
            if ($Scalar) { return $cmd.ExecuteScalar() }
            elseif ($NonQuery) { return $cmd.ExecuteNonQuery() }
            else {
                $dt = New-Object System.Data.DataTable
                $da = New-Object System.Data.SQLite.SQLiteDataAdapter($cmd); [void]$da.Fill($dt)
                if ($AsDataTable) { return $dt } else { return $dt | Select-Object * }
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
        try {
            if ($Scalar) {
                $q = Invoke-SqliteQuery -DataSource $Database -Query $Query -SqlParameters $SqlParameters
                if ($q -and $q.Count -gt 0) {
                    $first = $q | Select-Object -First 1
                    $firstProp = $first.PSObject.Properties | Select-Object -First 1
                    if ($firstProp) { return $firstProp.Value } else { return $null }
                }
                else { return $null }
            }
            elseif ($NonQuery) {
                [void](Invoke-SqliteQuery -DataSource $Database -Query $Query -SqlParameters $SqlParameters)
            }
            else {
                return Invoke-SqliteQuery -DataSource $Database -Query $Query -SqlParameters $SqlParameters
            }
        }
        catch { 
            Write-DbLog ERROR "Invoke-DbQuery (PSSQLite) error: Query='$Query'" $_.Exception
            throw 
        }
    }
}
