function Enable-UniqueIndex {
    param([Parameter(Mandatory)][string]$Database, [Parameter(Mandatory)][string]$Table, [Parameter(Mandatory)][string[]]$Columns)
    # BUG-034: a unique index that already covers exactly these columns (whatever its name) is reused.
    $existing = Get-DbUniqueIndexName -Database $Database -Table $Table -Columns $Columns
    if ($existing) { return $existing }
    $idxName = "ux_${Table}_" + (($Columns -join "_") -replace '[^A-Za-z0-9_]', '_')
    $taken = @(Invoke-DbQuery -Database $Database -Query "SELECT name FROM sqlite_master WHERE type='index' AND name=@n" -SqlParameters @{ n = $idxName })
    if ($taken.Count -gt 0) {
        # BUG-034: the derived name belongs to a different definition (for example columns a_b versus a,b,
        # or table a_b versus table a); append a short hash of the exact table and column list.
        $sha = [System.Security.Cryptography.SHA1]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Table + "`n" + ($Columns -join "`n")))
            $hash = (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8)
        }
        finally { $sha.Dispose() }
        $idxName = "${idxName}_$hash"
        $taken = @(Invoke-DbQuery -Database $Database -Query "SELECT name FROM sqlite_master WHERE type='index' AND name=@n" -SqlParameters @{ n = $idxName })
        if ($taken.Count -gt 0) { throw "Enable-UniqueIndex: index name '$idxName' already exists with a different definition" }
    }
    $cols = (($Columns | ForEach-Object { ConvertTo-Ident $_ })) -join ', '
    Invoke-DbQuery -Database $Database -Query "CREATE UNIQUE INDEX $(ConvertTo-Ident $idxName) ON $(ConvertTo-Ident $Table) ($cols)" -NonQuery | Out-Null
    return $idxName
}
