function Confirm-DbForeignKey {
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$From,      # table with FK column
        [Parameter(Mandatory)][string]$Column,    # fk column in From
        [Parameter(Mandatory)][string]$To,        # referenced table
        [string]$RefColumn = 'id',
        [ValidateSet('NO ACTION', 'RESTRICT', 'CASCADE', 'SET NULL')][string]$OnDelete = 'NO ACTION'
    )
    Initialize-Db -Database $Database

    # SQLite can't add FKs easily post-creation; use triggers for enforcement & optional cascade.
    $checkTrig = "trg_fk_${From}_${Column}_check"
    $delTrig = "trg_fk_${From}_${Column}_ondelete"

    $quotedFrom = ConvertTo-Ident $From; $quotedCol = ConvertTo-Ident $Column; $quotedTo = ConvertTo-Ident $To; $quotedRef = ConvertTo-Ident $RefColumn

    # BUG-030: SQLite accepts trigger bodies that reference a missing table or column and only
    # fails when the trigger fires, which would break every later INSERT into $From. Verify first.
    $refColumns = @(Get-TableColumns -Database $Database -TableName $To)
    if ($refColumns.Count -eq 0) {
        throw "Confirm-DbForeignKey: referenced table '$To' does not exist in '$Database'"
    }
    if ($refColumns -notcontains $RefColumn) {
        throw "Confirm-DbForeignKey: referenced column '$RefColumn' does not exist in table '$To'"
    }

    # BUG-027: keep the RAISE text ASCII so a Windows PowerShell build does not corrupt it.
    $violationMsg = "FK violation: $From.$Column -> $To.$RefColumn"

    # BUG-023: trigger names depend only on From/Column, so drop any earlier versions before
    # recreating; otherwise re-confirming with a new target or OnDelete leaves stale triggers.
    foreach ($trg in @($checkTrig, ($checkTrig + '_upd'), $delTrig)) {
        Invoke-DbQuery -Database $Database -Query "DROP TRIGGER IF EXISTS $(ConvertTo-Ident $trg)" -NonQuery | Out-Null
    }

    $checkSql = @"
CREATE TRIGGER $(ConvertTo-Ident $checkTrig)
BEFORE INSERT ON $quotedFrom
FOR EACH ROW BEGIN
    SELECT RAISE(ABORT, '$violationMsg')
    WHERE NEW.$quotedCol IS NOT NULL AND NOT EXISTS (SELECT 1 FROM $quotedTo WHERE $quotedTo.$quotedRef = NEW.$quotedCol);
END;
"@
    Invoke-DbQuery -Database $Database -Query $checkSql -NonQuery | Out-Null

    $updSql = @"
CREATE TRIGGER $(ConvertTo-Ident ($checkTrig + '_upd'))
BEFORE UPDATE OF $quotedCol ON $quotedFrom
FOR EACH ROW BEGIN
    SELECT RAISE(ABORT, '$violationMsg')
    WHERE NEW.$quotedCol IS NOT NULL AND NOT EXISTS (SELECT 1 FROM $quotedTo WHERE $quotedTo.$quotedRef = NEW.$quotedCol);
END;
"@
    Invoke-DbQuery -Database $Database -Query $updSql -NonQuery | Out-Null

    # BUG-022: every OnDelete mode needs a delete-time trigger on the parent, not only CASCADE.
    switch ($OnDelete) {
        'CASCADE' {
            $delSql = @"
CREATE TRIGGER $(ConvertTo-Ident $delTrig)
AFTER DELETE ON $quotedTo
FOR EACH ROW BEGIN
    DELETE FROM $quotedFrom WHERE $quotedFrom.$quotedCol = OLD.$quotedRef;
END;
"@
        }
        'SET NULL' {
            $delSql = @"
CREATE TRIGGER $(ConvertTo-Ident $delTrig)
AFTER DELETE ON $quotedTo
FOR EACH ROW BEGIN
    UPDATE $quotedFrom SET $quotedCol = NULL WHERE $quotedFrom.$quotedCol = OLD.$quotedRef;
END;
"@
        }
        default {
            # NO ACTION and RESTRICT: refuse to delete a parent row that still has children.
            $delSql = @"
CREATE TRIGGER $(ConvertTo-Ident $delTrig)
BEFORE DELETE ON $quotedTo
FOR EACH ROW BEGIN
    SELECT RAISE(ABORT, '$violationMsg')
    WHERE EXISTS (SELECT 1 FROM $quotedFrom WHERE $quotedFrom.$quotedCol = OLD.$quotedRef);
END;
"@
        }
    }
    Invoke-DbQuery -Database $Database -Query $delSql -NonQuery | Out-Null

    # Record as confirmed (compatible with older SQLite)
    $existingFk = Invoke-DbQuery -Database $Database -Query "SELECT column_name FROM __fks__ WHERE table_name=@t AND column_name=@c" -SqlParameters @{ t = $From; c = $Column }
    if ($existingFk) {
        # Update existing FK record
        Invoke-DbQuery -Database $Database -Query @"
UPDATE __fks__ SET 
  ref_table=@rt,
  ref_column=@rc,
  status='confirmed',
  on_delete=@od
WHERE table_name=@t AND column_name=@c
"@ -SqlParameters @{ t = $From; c = $Column; rt = $To; rc = $RefColumn; od = $OnDelete } -NonQuery | Out-Null
    } else {
        # Insert new FK record
        Invoke-DbQuery -Database $Database -Query @"
INSERT INTO __fks__(table_name,column_name,ref_table,ref_column,confidence,status,on_delete)
VALUES(@t,@c,@rt,@rc,1.0,'confirmed',@od)
"@ -SqlParameters @{ t = $From; c = $Column; rt = $To; rc = $RefColumn; od = $OnDelete } -NonQuery | Out-Null
    }
}
