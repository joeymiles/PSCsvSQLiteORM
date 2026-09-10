function New-DbQuery {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$From
    )
    # Honor -WhatIf: return nothing instead of building the object anyway (BUG-044).
    if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess("DbQuery from '$From'", 'Create object')) { return }
    return [DbQuery]::new($Database, $From)
}
