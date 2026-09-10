Function Set-DynamicORMClass {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param()
    # Each registered file is loaded once; a file that is missing or fails to parse is logged and does not stop the
    # remaining models from loading. All failures are reported together at the end (BUG-017 / BUG-018).
    $loaded = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $failures = @()
    foreach ($script in @($script:DynamicClassScripts)) {
        if (-not $script -or -not $script.ModelPath) { continue }
        $path = [string]$script.ModelPath
        if ($loaded.Contains($path)) { continue }
        [void]$loaded.Add($path)
        if (-not (Test-Path -LiteralPath $path)) {
            $failures += "Dynamic model file not found: $path"
            Write-DbLog -Level ERROR -Message "Dynamic model path not found: $path"
            continue
        }
        $target = "class from $path"
        $proceed = $true; if ($PSCmdlet) { $proceed = $PSCmdlet.ShouldProcess($target, 'Load') }
        if ($proceed) {
            try {
                . $path
            }
            catch {
                $failures += "Failed to load dynamic model file '$path': $($_.Exception.Message)"
                Write-DbLog -Level ERROR -Message "Failed to load dynamic model file '$path'" -Exception $_.Exception
            }
        }
    }
    if ($failures.Count -gt 0) {
        throw ("Set-DynamicORMClass could not load {0} dynamic model file(s):`n{1}" -f $failures.Count, ($failures -join "`n"))
    }
}
