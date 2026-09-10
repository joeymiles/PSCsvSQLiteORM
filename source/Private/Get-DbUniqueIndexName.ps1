function Get-DbUniqueIndexName {
    <#
    .SYNOPSIS
    Returns the name of an existing unique index on a table whose column list matches exactly.

    .DESCRIPTION
    BUG-034: Enable-UniqueIndex used to decide whether an index existed by name only, so two
    different column sets that produce the same derived name shared one index. This helper looks
    at the real index definitions (PRAGMA index_list / PRAGMA index_info) and returns the name of
    a unique index (explicit, UNIQUE constraint or primary key) covering exactly the given columns
    in the given order, or $null when there is none.
    #>
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string[]]$Columns
    )
    $wanted = @($Columns | ForEach-Object { [string]$_ })
    $indexes = @(Invoke-DbQuery -Database $Database -Query "PRAGMA index_list($(ConvertTo-Ident $Table))")
    foreach ($ix in $indexes) {
        if ([int]$ix.unique -ne 1) { continue }
        $cols = @(Invoke-DbQuery -Database $Database -Query "PRAGMA index_info($(ConvertTo-Ident ([string]$ix.name)))" |
            Sort-Object { [int]$_.seqno } | ForEach-Object { [string]$_.name })
        if ($cols.Count -ne $wanted.Count) { continue }
        $same = $true
        for ($i = 0; $i -lt $cols.Count; $i++) {
            if (-not [string]::Equals($cols[$i], $wanted[$i], [System.StringComparison]::OrdinalIgnoreCase)) { $same = $false; break }
        }
        if ($same) { return [string]$ix.name }
    }
    return $null
}
