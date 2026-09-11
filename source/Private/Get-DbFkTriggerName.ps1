function Get-DbFkTriggerName {
    <#
    .SYNOPSIS
    Resolves the foreign key trigger names that belong to one (table, column) pair.

    .DESCRIPTION
    E2E1-007: the trigger names were derived as trg_fk_<From>_<Column>_* by plain string
    concatenation, which is not injective: table 'ab' with column 'c_id' and table 'ab_c' with
    column 'id' both produce trg_fk_ab_c_id_check. Confirming the second relationship dropped and
    replaced the first relationship's triggers, silently disabling its enforcement.

    This helper decides which names a pair may use. Every trigger Confirm-DbForeignKey creates now
    carries an ownership marker comment (SQLite stores the CREATE statement verbatim in
    sqlite_master.sql, comments included), so a name already held by a DIFFERENT pair is detected
    and the pair falls back to a name carrying a short hash of the exact table and column - the
    same strategy Enable-UniqueIndex uses for index names. Triggers written by an earlier version
    of the module carry no marker; those are recognised by the table they are defined on (the two
    check triggers live on the child table) or by the "<From>"."<Column>" reference every ON DELETE
    trigger body contains.

    Returns the three names to create (Check, CheckUpd, Delete), the Marker to embed in them, and
    Owned: the triggers that already exist in the database and belong to this pair, under either
    the plain or the hashed base. Callers drop Owned before recreating or removing a relationship.
    #>
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$Column
    )
    # E2E1-021: ConvertTo-Ident used to reject every character outside \w, whitespace, dash,
    # underscore and dot, which kept '*/' out of the marker for free. It now accepts anything
    # double-quoting can carry, so a name may contain '*' or '/', and a literal '*/' inside the
    # marker would close this SQL comment early and leave the rest of the name standing as SQL in
    # the CREATE TRIGGER text. Percent-encode '%', '*' and '/' in the two marker fields. None of
    # those three was ever accepted by the old whitelist, so a marker written by an earlier version
    # of the module is unchanged and the ownership checks below still recognise it; the encoding is
    # reversible, so two different pairs still get two different markers.
    $quotedFrom = ConvertTo-Ident $From
    $quotedCol = ConvertTo-Ident $Column
    $markerFrom = ($From -replace '%', '%25') -replace '\*', '%2A' -replace '/', '%2F'
    $markerCol = ($Column -replace '%', '%25') -replace '\*', '%2A' -replace '/', '%2F'
    $marker = "/* psORM-fk table=$markerFrom column=$markerCol */"
    $bodyRef = $quotedFrom + '.' + $quotedCol

    $plainBase = "trg_fk_${From}_${Column}"
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($From + "`n" + $Column))
        $hash = (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8)
    }
    finally { $sha.Dispose() }
    $hashedBase = $plainBase + '_' + $hash

    $ordinalCi = [System.StringComparison]::OrdinalIgnoreCase
    $owned = @()
    $plainIsFree = $true
    foreach ($base in @($plainBase, $hashedBase)) {
        foreach ($suffix in @('_check', '_check_upd', '_ondelete')) {
            $name = $base + $suffix
            $rows = @(Invoke-DbQuery -Database $Database -Query "SELECT name, tbl_name, sql FROM sqlite_master WHERE type='trigger' AND name = @n COLLATE NOCASE" -SqlParameters @{ n = $name })
            if ($rows.Count -eq 0) { continue }
            $sqlValue = $rows[0].sql
            $sql = ''
            if ($null -ne $sqlValue -and $sqlValue -isnot [System.DBNull]) { $sql = [string]$sqlValue }
            $tbl = ''
            $tblValue = $rows[0].tbl_name
            if ($null -ne $tblValue -and $tblValue -isnot [System.DBNull]) { $tbl = [string]$tblValue }

            $isOwner = $false
            if ($sql.IndexOf($marker, $ordinalCi) -ge 0) { $isOwner = $true }
            elseif ($sql.IndexOf('psORM-fk', $ordinalCi) -ge 0) { $isOwner = $false }
            elseif ([string]::Equals($tbl, $From, $ordinalCi)) { $isOwner = $true }
            elseif ($bodyRef.Length -gt 0 -and $sql.IndexOf($bodyRef, $ordinalCi) -ge 0) { $isOwner = $true }

            if ($isOwner) { $owned += [string]$rows[0].name }
            elseif ($base -eq $plainBase) { $plainIsFree = $false }
            else { throw "Confirm-DbForeignKey: trigger name '$name' already exists and belongs to a different relationship" }
        }
    }

    $base = $hashedBase
    if ($plainIsFree) { $base = $plainBase }
    return [pscustomobject]@{
        Check    = $base + '_check'
        CheckUpd = $base + '_check_upd'
        Delete   = $base + '_ondelete'
        Marker   = $marker
        Owned    = $owned
    }
}
