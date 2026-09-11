function Format-DynamicAssociationLine {
    <#
    .SYNOPSIS
        Builds one generated association line for New-DynamicModel.
    .DESCRIPTION
        An entry is either the foreign key column name or a hashtable
        @{ Column = '<fk column>'; RefColumn = '<referenced column>' }. The referenced column is emitted as a
        third argument only when it is something other than the default 'id' (E2E1-006), so generated classes
        for ordinary relationships are unchanged.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('HasMany', 'BelongsTo')][string]$Method,
        [Parameter(Mandatory)][string]$RelatedTable,
        [object]$Entry
    )

    if ($null -eq $Entry) { return }

    $column = ''
    $refColumn = ''
    if ($Entry -is [System.Collections.IDictionary]) {
        $column = [string]$Entry['Column']
        if ($Entry.Contains('RefColumn')) { $refColumn = [string]$Entry['RefColumn'] }
    }
    else {
        $column = [string]$Entry
    }
    if ([string]::IsNullOrEmpty($column)) { return }

    $tableLiteral = $RelatedTable -replace "'", "''"
    $columnLiteral = $column -replace "'", "''"
    if ([string]::IsNullOrEmpty($refColumn) -or $refColumn -eq 'id') {
        return ('        $this.{0}(''{1}'',''{2}'');' -f $Method, $tableLiteral, $columnLiteral)
    }
    return ('        $this.{0}(''{1}'',''{2}'',''{3}'');' -f $Method, $tableLiteral, $columnLiteral, ($refColumn -replace "'", "''"))
}
