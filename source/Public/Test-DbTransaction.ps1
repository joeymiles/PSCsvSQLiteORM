function Test-DbTransaction {
    <#
    .SYNOPSIS
    Reports whether the pooled connection for a database is inside a transaction.

    .DESCRIPTION
    E2E1-003: every statement for one database goes through a single pooled
    System.Data.SQLite connection, so a transaction that was started and never
    completed silently takes in every later write and loses them all when the
    connection is closed. This function tells a script whether that is the case for
    -Database, so it can commit the work with Complete-DbTransaction or discard it
    with Undo-DbTransaction instead of finding out when the process ends.

    Returns $false when there is no pooled connection for the database (nothing can
    be pending), and never opens one.

    .PARAMETER Database
    Path of the database file.

    .EXAMPLE
    if (Test-DbTransaction -Database $db) { Complete-DbTransaction -Database $db }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Database)
    $key = Resolve-DbPath -Database $Database
    $conn = $null
    if ($script:DbPool -and $script:DbPool.ContainsKey($key)) { $conn = $script:DbPool[$key] }
    if (-not $conn) { return $false }
    return [bool](Test-DbConnectionInTransaction -Connection $conn -Key $key)
}
