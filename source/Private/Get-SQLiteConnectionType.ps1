function Get-SQLiteConnectionType {
    <#
    .SYNOPSIS
    Returns [System.Data.SQLite.SQLiteConnection] if the assembly is (or can be) loaded, otherwise $null.

    .DESCRIPTION
    PSSQLite (a required module) already loads System.Data.SQLite.dll, so the type
    is normally available without any Add-Type call. Add-Type -AssemblyName with a
    partial name fails on Windows PowerShell 5.1 because the assembly is not in
    the GAC; that path is only tried last.
    #>
    $t = 'System.Data.SQLite.SQLiteConnection' -as [type]
    if ($t) { return $t }
    $pssqlite = Get-Module -Name PSSQLite | Select-Object -First 1
    if ($pssqlite) {
        $arch = if ([IntPtr]::Size -eq 8) { 'x64' } else { 'x86' }
        $candidates = @(
            (Join-Path (Join-Path $pssqlite.ModuleBase $arch) 'System.Data.SQLite.dll'),
            (Join-Path (Join-Path (Join-Path $pssqlite.ModuleBase 'core') ('win-' + $arch)) 'System.Data.SQLite.dll')
        )
        foreach ($dll in $candidates) {
            if (Test-Path -LiteralPath $dll) {
                try { Add-Type -Path $dll -ErrorAction Stop | Out-Null } catch { }
                $t = 'System.Data.SQLite.SQLiteConnection' -as [type]
                if ($t) { return $t }
            }
        }
    }
    try { Add-Type -AssemblyName System.Data.SQLite -ErrorAction Stop | Out-Null } catch { }
    return ('System.Data.SQLite.SQLiteConnection' -as [type])
}
