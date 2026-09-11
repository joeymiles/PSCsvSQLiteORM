function Find-DbRelationships {
    param([Parameter(Mandatory)][string]$Database)

    function Get-RefColumn {
        param(
            [string]$Base,      # e.g., "user" from user_id
            [string]$RefTable,  # candidate ref table name: "user" or "users"
            [object[]]$RefCols  # __columns__ rows (column_name, pk) of the ref table
        )

        $norm = {
            param($s) ($s -replace '_', '').ToLower()
        }

        $baseN = & $norm $Base
        $refN = & $norm $RefTable

        # BUG-033: a single-column primary key is the natural target of a foreign key.
        $pkCols = @($RefCols | Where-Object { [int]$_.pk -gt 0 } | ForEach-Object { $_.column_name })
        $pkName = $null
        if ($pkCols.Count -eq 1) { $pkName = $pkCols[0] }

        $best = @{ name = $null; score = 0.0 }

        foreach ($col in $RefCols) {
            $c = $col.column_name
            $cN = & $norm $c

            $score =
            if ($pkName -and $c -eq $pkName) { 1.00 }
            elseif ($cN -eq 'id') { 1.00 }
            elseif ($cN -eq ($refN + 'id') -or $cN -eq ($baseN + 'id')) { 0.95 }
            # BUG-033: any other *_id column is a foreign key of the referenced table,
            # not its key; never suggest it.
            elseif ($c -match '_id$') { 0.0 }
            elseif ($cN -like ($baseN + '*') -or $cN -like ($refN + '*')) { 0.75 }
            elseif ($cN -like '*id*') { 0.60 }
            else { 0.0 }

            if ($score -gt $best.score) {
                $best.name = $c
                $best.score = $score
            }
        }

        # BUG-033: no fallback to a literal 'id'; the caller skips this candidate table
        # when none of its real columns looks like a key.
        if (-not $best.name) { return $null }

        return $best
    }

    # BUG-066: refresh the catalog first so tables created with plain SQL or migrations
    # are considered (Update-DbCatalog also runs Initialize-Db).
    # E2E1-004: -WhatIf:$false because this refresh is part of the lookup, not a separate operation
    # the caller can skip; skipping it leaves __tables__ missing and the whole function fails.
    Update-DbCatalog -Database $Database -WhatIf:$false -Confirm:$false

    $suggestions = New-Object System.Collections.ArrayList

    $tables = Invoke-DbQuery -Database $Database -Query "SELECT table_name FROM __tables__"
    $tableNames = @($tables | ForEach-Object { $_.table_name } | Where-Object { -not (Test-DbInternalTable -Name $_) })

    foreach ($tn in $tableNames) {
        $cols = Invoke-DbQuery -Database $Database -Query "SELECT column_name FROM __columns__ WHERE table_name=@t" -SqlParameters @{ t = $tn }
        foreach ($col in $cols) {
            $c = $col.column_name
            if ($c -notmatch '^(.*)_id$') { continue }
            $base = $Matches[1]

            # BUG-024: a relationship that was confirmed (Confirm-DbForeignKey or a real
            # FOREIGN KEY found by Update-DbCatalog) is authoritative. Report it as stored
            # and never overwrite its target with a heuristic guess.
            $existingFk = @(Invoke-DbQuery -Database $Database -Query "SELECT ref_table, ref_column, confidence, status FROM __fks__ WHERE table_name=@t AND column_name=@c" -SqlParameters @{ t = $tn; c = $c })
            if ($existingFk.Count -gt 0 -and $existingFk[0].status -and $existingFk[0].status -ne 'suggested') {
                [void]$suggestions.Add([pscustomobject]@{
                    table_name  = $tn
                    column_name = $c
                    ref_table   = $existingFk[0].ref_table
                    ref_column  = $existingFk[0].ref_column
                    confidence  = $existingFk[0].confidence
                    status      = $existingFk[0].status
                })
                continue
            }

            # BUG-024: __fks__ holds one row per (table, column), so evaluate every candidate
            # table and keep only the best one. On equal scores the table named exactly like
            # the column prefix wins over its plural.
            $candidates = @($tableNames | Where-Object { $_ -eq $base }) + @($tableNames | Where-Object { $_ -eq ($base + 's') })
            $bestRef = $null; $bestPick = $null
            foreach ($ref in $candidates) {
                $refCols = @(Invoke-DbQuery -Database $Database -Query "SELECT column_name, pk FROM __columns__ WHERE table_name=@rt" -SqlParameters @{ rt = $ref })
                $pick = Get-RefColumn -Base $base -RefTable $ref -RefCols $refCols
                if ($null -eq $pick) { continue }
                # A column cannot reference itself (teams.team_id -> teams.team_id).
                if ($ref -eq $tn -and $pick.name -eq $c) { continue }
                if ($null -eq $bestPick -or $pick.score -gt $bestPick.score) {
                    $bestRef = $ref; $bestPick = $pick
                }
            }
            if ($null -eq $bestPick) { continue }

            $conf = [math]::Round($bestPick.score, 2)
            if ($existingFk.Count -gt 0) {
                # Update the existing (still unconfirmed) suggestion
                Invoke-DbQuery -Database $Database -Query @"
UPDATE __fks__ SET
  ref_table=@rt,
  ref_column=@rc,
  confidence=@conf,
  status='suggested'
WHERE table_name=@t AND column_name=@c
"@ -SqlParameters @{ t = $tn; c = $c; rt = $bestRef; rc = $bestPick.name; conf = $conf } -NonQuery | Out-Null
            } else {
                # Insert new FK suggestion
                Invoke-DbQuery -Database $Database -Query @"
INSERT INTO __fks__(table_name,column_name,ref_table,ref_column,confidence,status)
VALUES(@t,@c,@rt,@rc,@conf,'suggested')
"@ -SqlParameters @{ t = $tn; c = $c; rt = $bestRef; rc = $bestPick.name; conf = $conf } -NonQuery | Out-Null
            }

            [void]$suggestions.Add([pscustomobject]@{
                table_name  = $tn
                column_name = $c
                ref_table   = $bestRef
                ref_column  = $bestPick.name
                confidence  = $conf
                status      = 'suggested'
            })
        }
    }
    return $suggestions
}
