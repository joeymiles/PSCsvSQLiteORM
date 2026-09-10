function Find-DbRelationships {
    param([Parameter(Mandatory)][string]$Database)

    function Get-RefColumn {
        param(
            [string]$Base,      # e.g., "user" from user_id
            [string]$RefTable,  # candidate ref table name: "user" or "users"
            [string[]]$RefCols  # column names in ref table
        )

        $norm = {
            param($s) ($s -replace '_', '').ToLower()
        }

        $baseN = & $norm $Base
        $refN = & $norm $RefTable

        $best = @{ name = $null; score = 0.0 }

        foreach ($col in $RefCols) {
            $c = $col
            $cN = & $norm $c

            $score =
            if ($cN -eq 'id') { 1.00 }
            elseif ($cN -eq ($refN + 'id') -or $cN -eq ($baseN + 'id')) { 0.95 }
            elseif ($c -match '_id$') { 0.85 }
            elseif ($cN -like ($baseN + '*') -or $cN -like ($refN + '*')) { 0.75 }
            elseif ($cN -like '*id*') { 0.60 }
            else { 0.0 }

            if ($score -gt $best.score) {
                $best.name = $c
                $best.score = $score
            }
        }

        if (-not $best.name) {
            # absolute fallback
            $best = @{ name = 'id'; score = 0.50 }
        }

        return $best
    }

    Initialize-Db -Database $Database

    $suggestions = New-Object System.Collections.ArrayList

    $tables = Invoke-DbQuery -Database $Database -Query "SELECT table_name FROM __tables__"
    $tableNames = @($tables | ForEach-Object { $_.table_name } | Where-Object { -not (Test-DbInternalTable -Name $_) })

    foreach ($tn in $tableNames) {
        $cols = Invoke-DbQuery -Database $Database -Query "SELECT column_name FROM __columns__ WHERE table_name=@t" -SqlParameters @{ t = $tn }
        foreach ($col in $cols) {
            $c = $col.column_name
            if ($c -match '^(.*)_id$') {
                $base = $Matches[1]
                $candidates = $tableNames | Where-Object { $_ -eq $base -or $_ -eq ($base + 's') }

                foreach ($ref in $candidates) {
                    $refCols = (Invoke-DbQuery -Database $Database -Query "SELECT column_name FROM __columns__ WHERE table_name=@rt" -SqlParameters @{ rt = $ref } | ForEach-Object { $_.column_name })
                    $pick = Get-RefColumn -Base $base -RefTable $ref -RefCols $refCols

                    # Check if FK suggestion exists (compatible with older SQLite)
                    $existingFk = Invoke-DbQuery -Database $Database -Query "SELECT status FROM __fks__ WHERE table_name=@t AND column_name=@c" -SqlParameters @{ t = $tn; c = $c }
                    if ($existingFk) {
                        # Update existing FK suggestion
                        $currentStatus = $existingFk[0].status
                        Invoke-DbQuery -Database $Database -Query @"
UPDATE __fks__ SET 
  ref_table=@rt,
  ref_column=@rc,
  confidence=@conf,
  status=COALESCE(@curstat,'suggested')
WHERE table_name=@t AND column_name=@c
"@ -SqlParameters @{ t = $tn; c = $c; rt = $ref; rc = $pick.name; conf = [math]::Round($pick.score, 2); curstat = $currentStatus } -NonQuery | Out-Null
                    } else {
                        # Insert new FK suggestion
                        Invoke-DbQuery -Database $Database -Query @"
INSERT INTO __fks__(table_name,column_name,ref_table,ref_column,confidence,status)
VALUES(@t,@c,@rt,@rc,@conf,'suggested')
"@ -SqlParameters @{ t = $tn; c = $c; rt = $ref; rc = $pick.name; conf = [math]::Round($pick.score, 2) } -NonQuery | Out-Null
                    }

                    [void]$suggestions.Add([pscustomobject]@{
                        table_name  = $tn
                        column_name = $c
                        ref_table   = $ref
                        ref_column  = $pick.name
                        confidence  = [math]::Round($pick.score, 2)
                        status      = 'suggested'
                    })
                }
            }
        }
    }
    return $suggestions
}

