function Set-DbLogging {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')] [string]$Level = 'INFO',
        [string]$Path
    )
    # E2E1-022: apply only the parameters the caller actually supplied. Assigning
    # $Level unconditionally made 'Set-DbLogging -Path <file>' silently reset an
    # existing DEBUG threshold back to the 'INFO' parameter default.
    $setLevel = $PSBoundParameters.ContainsKey('Level')
    $setPath = $PSBoundParameters.ContainsKey('Path')
    if (-not $setLevel -and -not $setPath) { return }
    $changes = @()
    if ($setLevel) { $changes += "level to $Level" }
    if ($setPath) {
        if ([string]::IsNullOrEmpty($Path)) { $changes += 'log path to (none)' }
        else { $changes += "log path to $Path" }
    }
    $proceed = $true
    if ($PSCmdlet) { $proceed = $PSCmdlet.ShouldProcess('ModuleState', ('Set logging ' + ($changes -join ' and '))) }
    if ($proceed) {
        if ($setLevel) { $script:DbLogLevel = $Level }
        if ($setPath) { $script:DbLogPath = $Path }
    }
}
