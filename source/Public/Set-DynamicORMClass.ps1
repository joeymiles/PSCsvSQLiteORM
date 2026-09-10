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
                # A dot-sourced class is only resolvable by name inside the scope that loaded it (BUG-035): capture the
                # [type] here, right after loading, so New-DynamicRecord and related-record navigation can construct
                # instances from any scope.
                $typeObj = $null
                if ($script.PSObject.Properties['TypeName'] -and $script.TypeName) {
                    $typeObj = ([System.Management.Automation.PSTypeName]([string]$script.TypeName)).Type
                }
                if ($typeObj) {
                    if (-not $script:ModelTypeObjects) { $script:ModelTypeObjects = @{} }
                    $script:ModelTypeObjects[[string]$script.Table] = $typeObj
                    if ($script.PSObject.Properties['DatabaseKey'] -and $script.DatabaseKey) {
                        # Static store on the base class: reachable from class methods even after a module re-import
                        [DynamicActiveRecord]::DynamicModelTypes[[string]$script.DatabaseKey + '|' + [string]$script.Table] = $typeObj
                        if ($script:ModelRegistry -and $script:ModelRegistry.ContainsKey($script.DatabaseKey) -and
                            $script:ModelRegistry[$script.DatabaseKey].ContainsKey([string]$script.Table)) {
                            $script:ModelRegistry[$script.DatabaseKey][[string]$script.Table].Type = $typeObj
                        }
                    }
                }
                else {
                    $failures += "Dynamic model file '$path' loaded but type '$($script.TypeName)' could not be resolved"
                    Write-DbLog -Level ERROR -Message "Dynamic model type '$($script.TypeName)' not resolvable after loading '$path'"
                }
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
