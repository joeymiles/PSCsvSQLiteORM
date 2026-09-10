function New-DynamicModel {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param (
        [Parameter(Mandatory)][string]$TableName,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string[]]$Columns,
        [hashtable]$HasMany = @{},
        [hashtable]$BelongsTo = @{}
    )

    if (-not $script:DynamicClassScripts) {
        $script:DynamicClassScripts = [System.Collections.ArrayList]::new()
    } elseif ($script:DynamicClassScripts -isnot [System.Collections.ArrayList]) {
        # Safety: Wrap non-ArrayList (e.g., single PSCustomObject or other) into a new ArrayList
        $newList = [System.Collections.ArrayList]::new()
        if ($script:DynamicClassScripts) {
            [void]$newList.Add($script:DynamicClassScripts)
        }
        $script:DynamicClassScripts = $newList
    }
    # Registries keyed by database (BUG-017): type name owners and per-database model entries
    if (-not $script:DynamicTypeOwners) { $script:DynamicTypeOwners = @{} }
    if (-not $script:ModelRegistry) { $script:ModelRegistry = @{} }

    # Ensure base class exists first
    if (-not ([System.Management.Automation.PSTypeName]'DynamicActiveRecord').Type) {
        throw "DynamicActiveRecord must be loaded before emitting '$TableName'."
    }

    $dbKey = Get-DynamicDatabaseKey -Database $Database
    $owner = $dbKey + '|' + $TableName

    # ---- Build the type name (BUG-036): injective derivation, never an existing non-dynamic type, and unique per
    # (database, table) within this session. The first registrant keeps the readable name; a different database or
    # table that derives the same name gets a hash suffix.
    $typeName = Get-DynamicTypeName -TableName $TableName
    $candidate = $typeName
    $attempt = 0
    while ($true) {
        $ownedBy = $script:DynamicTypeOwners[$candidate]
        $reservedType = $false
        if (-not $ownedBy) { $reservedType = [bool](([System.Management.Automation.PSTypeName]$candidate).Type) }
        if ((-not $ownedBy -and -not $reservedType) -or ($ownedBy -eq $owner)) { break }
        $attempt++
        $candidate = $typeName + '_' + (Get-DynamicNameHash -Text $owner)
        if ($attempt -gt 1) { $candidate += '_' + $attempt }
    }
    $typeName = $candidate

    # ---- Member names (BUG-002 / BUG-018): a column accessor must never hide a base-class or System.Object member,
    # must not be a PowerShell keyword, and sanitized identifiers must be unique per class (case-insensitive).
    $reserved = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $flags = [System.Reflection.BindingFlags]'Public,NonPublic,Instance,Static,FlattenHierarchy'
    foreach ($mi in ([System.Management.Automation.PSTypeName]'DynamicActiveRecord').Type.GetMembers($flags)) { [void]$reserved.Add($mi.Name) }
    foreach ($mi in [object].GetMembers($flags)) { [void]$reserved.Add($mi.Name) }
    [void]$reserved.Add($typeName)
    $keywords = @('begin', 'break', 'catch', 'class', 'continue', 'data', 'define', 'do', 'dynamicparam', 'else', 'elseif',
        'end', 'enum', 'exit', 'filter', 'finally', 'for', 'foreach', 'from', 'function', 'hidden', 'if', 'in', 'inlinescript',
        'parallel', 'param', 'process', 'return', 'sequence', 'static', 'switch', 'throw', 'trap', 'try', 'until', 'using',
        'var', 'while', 'workflow', 'base', 'this')
    foreach ($kw in $keywords) { [void]$reserved.Add($kw) }

    $used = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $members = @()
    foreach ($col in $Columns) {
        if ($col -eq 'id') { continue }
        # Sanitize the class member identifier but keep the original column key for Get/SetAttribute
        $ident = ($col -replace '[^A-Za-z0-9_]', '_')
        if ([string]::IsNullOrEmpty($ident)) { $ident = 'Col' }
        if ($ident -match '^[0-9]') { $ident = '_' + $ident }
        if ($reserved.Contains($ident)) { $ident = 'Col_' + $ident }
        $base = $ident; $n = 1
        while ($used.Contains($ident) -or $used.Contains('_' + $ident) -or $reserved.Contains('_' + $ident)) {
            $n++; $ident = '{0}_{1}' -f $base, $n
        }
        [void]$used.Add($ident); [void]$used.Add('_' + $ident)
        $members += [pscustomobject]@{ Column = $col; Ident = $ident }
    }

    # ---- Hidden backing fields template
    $backingFieldTemplate = @'
    hidden [object] $_{0}
'@

    # ---- Property-like method template (overloaded methods)
    $propTemplate = @'
    # Property-like methods for {1}
    [object] {0}() {{
        return $this.GetAttribute('{1}')
    }}

    [void] {0}([object] $value) {{
        $this.SetAttribute('{1}', $value)
    }}
'@

    # Generate backing fields and property methods (skip 'id' if it's special). Single quotes in column names are
    # doubled so the generated literals stay valid.
    $backingFields = ($members | ForEach-Object { $backingFieldTemplate -f $_.Ident }) -join "`n"

    $propDefs = ($members | ForEach-Object { $propTemplate -f $_.Ident, ($_.Column -replace "'", "''") }) -join "`n"

    # ---- Constructor column list for base(...)
    $ctorCols = ($Columns | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '

    # ---- Associations (emit literal $this.* without string expansion)
    # A value is one foreign key column or a list of them (a child with several foreign keys to the same parent,
    # BUG-019); one association line is emitted per column, in the given order.
    $hmLines = ($HasMany.GetEnumerator() | ForEach-Object {
            $relTable = [string]$_.Key
            foreach ($fkCol in @($_.Value)) {
                if ($null -eq $fkCol) { continue }
                '        $this.HasMany(''{0}'',''{1}'');' -f ($relTable -replace "'", "''"), ([string]$fkCol -replace "'", "''")
            }
        }) -join "`n"

    $btLines = ($BelongsTo.GetEnumerator() | ForEach-Object {
            $relTable = [string]$_.Key
            foreach ($fkCol in @($_.Value)) {
                if ($null -eq $fkCol) { continue }
                '        $this.BelongsTo(''{0}'',''{1}'');' -f ($relTable -replace "'", "''"), ([string]$fkCol -replace "'", "''")
            }
        }) -join "`n"

    # ---- Class template with property-like methods
    $classTemplate = @'
class {0} : DynamicActiveRecord {{

{6}

    {0}([string]$database) : base('{1}', $database, @({2})) {{
{3}
{4}
    }}

{5}
}}
'@

    $classDefinition = $classTemplate -f $typeName, ($TableName -replace "'", "''"), $ctorCols, $hmLines, $btLines, $propDefs, $backingFields

    # ---- Emit into the per-session model directory; the file name is unique per (database, table)
    $fileBase = ($TableName -replace '[^A-Za-z0-9_]', '_')
    if ($fileBase.Length -gt 40) { $fileBase = $fileBase.Substring(0, 40) }
    $temp = Join-Path (Get-DynamicModelDirectory) ("dyn_{0}_{1}.ps1" -f $fileBase, (Get-DynamicNameHash -Text $owner))
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue
    }
    $proceed = $true; if ($PSCmdlet) { $proceed = $PSCmdlet.ShouldProcess($temp, 'Write dynamic class file') }
    if ($proceed) {
        Set-Content -LiteralPath $temp -Value $classDefinition -Encoding UTF8
    }

    $proceed = $true; if ($PSCmdlet) { $proceed = $PSCmdlet.ShouldProcess('DynamicClassScripts', "Register $typeName") }
    if ($proceed) {
        # Replace any previous entry for this (database, table) instead of accumulating duplicates (BUG-017)
        $stale = @($script:DynamicClassScripts | Where-Object {
            $_ -and (($_.ModelPath -eq $temp) -or (($_.Table -eq $TableName) -and ($_.PSObject.Properties['DatabaseKey']) -and ($_.DatabaseKey -eq $dbKey)))
        })
        foreach ($s in $stale) { $script:DynamicClassScripts.Remove($s) }
        [void]$script:DynamicClassScripts.Add([pscustomobject]@{
        Table       = $TableName
        Database    = $Database
        DatabaseKey = $dbKey
        TypeName    = $typeName
        ModelPath   = $temp
        })
        $script:DynamicTypeOwners[$typeName] = $owner
        if (-not $script:ModelRegistry.ContainsKey($dbKey)) { $script:ModelRegistry[$dbKey] = @{} }
        $script:ModelRegistry[$dbKey][$TableName] = @{
            TypeName  = $typeName
            ModelPath = $temp
            Columns   = [string[]]$Columns
            Members   = @($members | ForEach-Object { @{ Column = $_.Column; Member = $_.Ident } })
            Type      = ([System.Management.Automation.PSTypeName]$typeName).Type
        }
    }

    return $typeName
}
