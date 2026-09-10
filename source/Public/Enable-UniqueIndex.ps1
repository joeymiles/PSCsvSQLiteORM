function Enable-UniqueIndex {
    param([Parameter(Mandatory)][string]$Database, [Parameter(Mandatory)][string]$Table, [Parameter(Mandatory)][string[]]$Columns)
    $idxName = "ux_${Table}_" + (($Columns -join "_") -replace '[^A-Za-z0-9_]', '_')
    $exists = @(Invoke-DbQuery -Database $Database -Query "SELECT name FROM sqlite_master WHERE type='index' AND name=@n" -SqlParameters @{ n = $idxName })
    if ($exists.Count -eq 0) {
        $cols = (($Columns | ForEach-Object { ConvertTo-Ident $_ })) -join ', '
        Invoke-DbQuery -Database $Database -Query "CREATE UNIQUE INDEX IF NOT EXISTS $(ConvertTo-Ident $idxName) ON $(ConvertTo-Ident $Table) ($cols)" -NonQuery | Out-Null
    }
    return $idxName
}

