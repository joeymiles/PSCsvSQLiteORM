function Remove-DbForeignKey {
    <#
    .SYNOPSIS
    Removes a relationship created by Confirm-DbForeignKey.

    .DESCRIPTION
    E2E1-008: Confirm-DbForeignKey enforces a relationship with triggers, and one of them lives on
    the PARENT table. SQLite drops a trigger only with the table it is defined on, so dropping the
    child table (a normal migration step) used to leave that trigger behind, pointing at a table
    that no longer exists; every later DELETE on the parent then failed with "no such table" and
    the module exported no supported way to clean it up. This command is that way: it drops the
    whole trigger set of the relationship and removes its __fks__ catalog row.

    Removing a relationship that is not there is not an error, so the command is safe to call
    defensively before dropping a table.

    .EXAMPLE
    Remove-DbForeignKey -Database .\app.db -From vulns -Column asset_id
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$From,      # table with FK column
        [Parameter(Mandatory)][string]$Column     # fk column in From
    )
    if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess($Database, "Remove foreign key $From.$Column")) { return }
    Initialize-Db -Database $Database
    $dropped = @(Remove-DbFkTrigger -Database $Database -From $From -Column $Column)
    Invoke-DbQuery -Database $Database -Query "DELETE FROM __fks__ WHERE table_name=@t AND column_name=@c" -SqlParameters @{ t = $From; c = $Column } -NonQuery | Out-Null
    Write-DbLog INFO "Remove-DbForeignKey: $From.$Column removed ($($dropped.Count) trigger(s) dropped)"
    return $dropped
}
