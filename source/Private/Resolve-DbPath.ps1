function Resolve-DbPath {
    <#
    .SYNOPSIS
    Returns the canonical file system path for a -Database value.

    .DESCRIPTION
    Relative paths are resolved against the PowerShell current location (not the
    process working directory) and normalised with [IO.Path]::GetFullPath so that
    every spelling of one file ('.\a.db', 'C:/x/a.db', 'C:\x\a.db') maps to the
    same connection-pool key. In-memory and URI data sources are returned as-is.
    #>
    param([Parameter(Mandatory)][string]$Database)
    if ($Database -match '^\s*:memory:\s*$' -or $Database -match '^\s*file:') { return $Database }
    try {
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Database)
        return [System.IO.Path]::GetFullPath($resolved)
    }
    catch {
        return $Database
    }
}
