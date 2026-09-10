function Test-DbInternalTable {
    <#
    .SYNOPSIS
    Returns $true when a table name belongs to the module bookkeeping tables.

    .DESCRIPTION
    The catalog (__tables__, __columns__, __fks__) and the schema_migrations table are
    maintained by the module itself and must never be cataloged, related or exported
    as user data. SQLite internal tables (sqlite_*) are treated the same way.
    #>
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    if ($Name -like 'sqlite_%') { return $true }
    return ($Name -in @('__tables__', '__columns__', '__fks__', 'schema_migrations'))
}
