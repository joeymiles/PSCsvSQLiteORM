function ConvertFrom-DbDataTable {
    <#
    .SYNOPSIS
        Converts a DataTable into plain PSCustomObjects with one property per column.
    .DESCRIPTION
        Piping a DataTable through Select-Object * leaks DataRow members (RowError,
        RowState, Table, ItemArray, HasErrors) and returns [DBNull] for NULL cells.
        This helper projects only the result columns and maps DBNull to $null so the
        direct System.Data.SQLite path returns the same shape as the PSSQLite path.
    #>
    param([Parameter(Mandatory)][System.Data.DataTable]$DataTable)
    $names = @(foreach ($c in $DataTable.Columns) { $c.ColumnName })
    foreach ($r in $DataTable.Rows) {
        $o = [ordered]@{}
        foreach ($n in $names) {
            $v = $r[$n]
            if ($v -is [System.DBNull]) { $v = $null }
            $o[$n] = $v
        }
        [pscustomobject]$o
    }
}
