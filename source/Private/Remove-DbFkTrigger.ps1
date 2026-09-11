function Remove-DbFkTrigger {
    <#
    .SYNOPSIS
    Drops the foreign key triggers that belong to one (table, column) pair.

    .DESCRIPTION
    E2E1-008: SQLite drops a trigger only together with the table the trigger is defined ON, and
    Confirm-DbForeignKey puts its ON DELETE trigger on the PARENT table while the body names the
    child table. Dropping the child therefore leaves a trigger behind that makes every later DELETE
    on the surviving parent fail with "no such table"; dropping the parent leaves the two check
    triggers on the child, which breaks every INSERT into it. Both Remove-DbForeignKey and the
    Update-DbCatalog cleanup use this helper to take the whole trigger set away.

    Only triggers this pair owns are dropped (see Get-DbFkTriggerName), so a name shared with a
    different relationship is never touched. Returns the names that were dropped.
    #>
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$Column
    )
    $names = Get-DbFkTriggerName -Database $Database -From $From -Column $Column
    $dropped = @()
    foreach ($name in @($names.Owned)) {
        Invoke-DbQuery -Database $Database -Query "DROP TRIGGER IF EXISTS $(ConvertTo-Ident $name)" -NonQuery | Out-Null
        $dropped += $name
    }
    return $dropped
}
