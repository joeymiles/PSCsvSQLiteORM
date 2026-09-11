# PSCsvSQLiteORM

SQLite ORM for Windows PowerShell 5.1 and PowerShell 7 with CSV import, schema inference, dynamic models, relationships, joins, upserts, and migrations. Requires PSSQLite 1.1.0 or later.

## Quick Start

### 1. Install Dependencies
```powershell
# Install required PSSQLite module
Install-Module PSSQLite -Scope CurrentUser

# Install PSCsvSQLiteORM from PowerShell Gallery (latest version)
Install-Module PSCsvSQLiteORM -Scope CurrentUser

# Or install specific version 3.2.0
Install-Module PSCsvSQLiteORM -RequiredVersion 3.2.0 -Scope CurrentUser
```
This documentation describes 3.2.0, which exports 29 commands. `New-DynamicRecord` (step 6),
`Remove-DbForeignKey` and `Test-DbTransaction` (step 9) do not exist in 3.1.3 or earlier, so pin 3.2.0 or
later rather than an older version.

### 2. Initialize the ORM
```powershell
# Import the module
Import-Module PSCsvSQLiteORM

# Initialize with logging (optional but recommended)
Initialize-ORMVars -LogLevel DEBUG -LogPath 'C:\temp\orm.log'

# Or use a settings file for configuration (a sample ships as Examples\orm.settings.ps1 inside the module folder)
Initialize-ORMVars -SettingsPath .\orm.settings.ps1
```

The log directory is created on first write, the file is UTF-8, and writers from several sessions may share one
file. A log path that cannot be written is reported once as a warning; logging failures never abort database calls.

- `Write-DbLog -Message '<text>'` records the message as INFO: `-Level` is optional and defaults to INFO,
  and an unrecognised level is treated as INFO too. A defaulted level is filtered by the configured
  threshold exactly like an explicit `INFO`, so it is suppressed while the threshold is `WARN` or `ERROR`.
- `Set-DbLogging` changes only the parameters you pass: `Set-DbLogging -Path <file>` redirects the log and
  leaves the current level alone, and `Set-DbLogging -Level DEBUG` raises the level without clearing the
  path. `Set-DbLogging -Path ''` stops writing to a file and falls back to `Write-Verbose`, and
  `Set-DbLogging` with no parameters does nothing at all. Use `Initialize-ORMVars` to reset to the defaults.
- The settings script is dot-sourced and the **last hashtable it emits** is used, so it may create its own
  log directory or write other output first. A script that emits no hashtable throws
  `Failed to load settings from '<path>': the script did not return a hashtable with keys DbPath, LogPath, LogLevel`
  and leaves the previous configuration in place. The settings object must be a `[hashtable]`; an
  `[ordered]` hashtable is not accepted, and explicit parameters win over the file.
- The sample settings script ships inside the built module as `Examples\orm.settings.ps1`, and the reference
  topic ships both as `docs\about_PSCsvSQLiteORM.help.txt` and as `en-US\about_PSCsvSQLiteORM.help.txt`
  inside the module, so `Get-Help about_PSCsvSQLiteORM` answers from the module itself.
- `Initialize-ORMVars` with no parameters resets everything it manages to the built-in defaults: the
  connection pool, any pending transaction, the pragma cache, the log path and level, the default database
  path and every dynamic model registration. After a bare `Initialize-ORMVars`, `New-DynamicRecord` throws
  `No dynamic model is registered for table ...` until step 4 is run again. Type names already handed out
  stay reserved for the life of the session, because a PowerShell class cannot be unloaded.

### 3. Import CSV Data
```powershell
# Import CSV files into the SQLite database (the table is created from the CSV headers)
Import-CsvToSqlite -CsvPath .\data\assets.csv -Database .\myapp.db -TableName assets
Import-CsvToSqlite -CsvPath .\data\vulns.csv -Database .\myapp.db -TableName vulns

# Append more rows to a table that already exists without touching its schema (optional)
Import-CsvToSqlite -CsvPath .\data\assets_more.csv -Database .\myapp.db -TableName assets -SchemaMode AppendOnly

# Discover foreign keys from *_id column names, then confirm the ones you want.
# Confirmed relationships drive 'Auto' joins (step 5) and GetHasMany()/GetBelongsTo() navigation (step 6).
Find-DbRelationships -Database .\myapp.db
Confirm-DbForeignKey -Database .\myapp.db -From vulns -Column asset_id -To assets
```
`-SchemaMode` controls what an import may do to the table (default `Relaxed`):
- `Relaxed`: creates the table when it is missing, adds a column for every CSV header the table lacks, then
  inserts the rows. It may also **change the declared type of a column that already exists** when the CSV
  holds values the declared type cannot hold (an `INTEGER` column that receives text becomes `TEXT`). That
  rebuilds the table and rewrites every value already stored in the column, so the import writes a warning:
  `Import-CsvToSqlite: column '<c>' of table '<t>' is changed from <old> to <new>; the values already stored in it are rewritten.`
  The rebuild runs in one transaction and restores the table's indexes and triggers (including triggers on
  other tables, such as the ones `Confirm-DbForeignKey` creates), or leaves the database untouched.
  Decimal formatting alone is not a type change: a declared `REAL` or `INTEGER` column that receives `10.0`
  or `1.10` keeps its numeric type and stores the number, losing the trailing zero exactly as any value
  stored in a numeric column would. Type inference for a column the table does not have yet is unaffected -
  `10.0` in a new column is still inferred `TEXT` and stored verbatim.
- `Strict`: never creates or alters a table. The table must already exist (a fresh database throws
  `Strict mode: table '<table>' does not exist.`) and a CSV header that is not a column of the table throws
  `Strict mode: missing column <name> in <table>` before any row is inserted. A column whose declared type
  is narrower than the CSV values throws as well
  (`Strict mode: column '<c>' in table '<t>' is declared INTEGER but the CSV contains TEXT values; use -SchemaMode Relaxed to widen the column`).
- `AppendOnly`: only inserts rows. The table must already exist (a fresh database throws
  `AppendOnly mode: table '<table>' does not exist.`) and its schema is never changed, so use it for the second and
  later loads of a table, never for the first.

Every mode appends rows; nothing is deleted or replaced.

`id` columns and uniqueness:
- An `id` header becomes `INTEGER PRIMARY KEY AUTOINCREMENT` (or `TEXT PRIMARY KEY` for non-integer ids)
  **only when the import creates the table**. Blank ids are then numbered past every id already known.
- When an `id` column is added to a table that already exists, SQLite's `ALTER TABLE` cannot add a primary
  key, so the column is a plain `INTEGER` (or `TEXT`) column and the uniqueness is created as a unique index
  named `ux_<table>_id` instead. Blank ids are not auto-numbered in that case.
- Either way, importing a file whose ids are already in the table fails with a UNIQUE constraint error.

What the import does to the values it reads:
- `-NullTokens` (default `''`, `NULL`, `N/A`, `NaN`) are replaced with SQL NULL. Matching is case-sensitive,
  so a surname `Null` or a code `nan` is kept; pass `-IgnoreNullTokenCase` for case-insensitive matching, or
  `-NullTokens @()` to disable it.
- `-BoolTokens` (default true = `true,1,yes,y` / false = `false,0,no,n`) converts a column to INTEGER 1/0,
  but only when EVERY non-null value in the file is a bool token AND the file contains both a true token and
  a false token, or the table already declares that column with a numeric type. A column of only `Y`, only
  `NO` or only `true` is kept as text, and a column the table already declares TEXT/CHAR/CLOB/BLOB (or with
  no declared type) is never re-encoded. Pass `-BoolTokens @{}` to disable it.
- `-BatchSize` (default `0`) is the progress interval: `0` imports in one pass with no `Write-Progress`, and
  a value above `0` reports progress every N rows.
- `-ForeignKeys` takes column names to record as relationship candidates in the catalog for this table.

Other rules of an import:
- The command returns the trimmed CSV header names. Assign or pipe the result (`| Out-Null`) when you do not
  want the column names in your own output.
- `-WhatIf` and `-Confirm` are supported. Under `-WhatIf` the CSV, the headers, the table's existence in
  `Strict`/`AppendOnly` mode and the column types are all validated, the operation is reported, nothing is
  written (an empty database file may still be created when the path does not exist) and the header list is
  still returned.
- A failed import leaves the schema as it found it: the `CREATE TABLE` and `ALTER TABLE ADD COLUMN` of a run
  are rolled back with its rows. (This holds while the module has a direct `System.Data.SQLite` connection,
  which is the normal case; on the PSSQLite fallback path statements auto-commit.)
- A CSV wider than 999 columns is refused before anything is created, because SQLite binds at most 999
  parameters per statement; split the file.
- A header field that is empty or only whitespace throws `CSV header contains an empty column name.` rather
  than being imported under a generated name, headers are trimmed, and duplicate names after trimming throw.
- `-TableName` is trimmed too, and an all-whitespace name throws `TableName is empty.`. A table created by
  an older version under a padded name will not be found by the trimmed spelling.
- A CSV cell containing a NUL character (U+0000) aborts the import with an error naming the column and the
  1-based row number, and the transaction is rolled back, so no truncated row is written.

Table and column names (CSV headers included) may contain any character except control characters. Names are
always double-quoted in the generated SQL and an embedded double quote is doubled, so punctuation such as
parentheses, brackets, `%`, `/`, `+`, `?`, `$` and an apostrophe is accepted: `Cost (USD)`, `50%`, `A/B`,
`O'Brien` and `Weight [kg]` are all valid column names. A name containing a control character (U+0000 above
all, which SQLite reads as the end of the identifier) is refused with
`Invalid identifier: '<name>' contains control characters`.

`Confirm-DbForeignKey` records the relationship in the catalog and enforces it with triggers, so it first
checks the data already in the child table:
- Rows whose foreign key value is not in the referenced column make the call fail with
  `Confirm-DbForeignKey: <n> row(s) in '<From>' have a '<Column>' value that is not in <To>.<RefColumn>. Fix the data, or pass -Force to enforce the relationship for future writes only.`
  Clean the data, or pass `-Force` to record and enforce the relationship anyway - `-Force` warns instead of
  failing and leaves the offending rows in place, because the triggers only police future writes. A NULL
  foreign key value is never a violation. This matters for the "import the CSVs first, then confirm"
  workflow above: imported data that is not clean now has to be fixed or forced.
- `-RefColumn` (default `id`) names the column on the parent table that the foreign key points at, and it is
  honoured end to end: `GetHasMany()` / `GetBelongsTo()` navigate through that column (step 6).
- The triggers are named `trg_fk_<From>_<Column>_check`, `_check_upd` and `_ondelete` unless those names
  already belong to a different (table, column) pair, in which case the new pair gets
  `trg_fk_<From>_<Column>_<8 hex characters>_*`. Do not build the names by hand: use `Remove-DbForeignKey`
  (step 9) or read `sqlite_master`.
- `Update-DbCatalog` drops the foreign key triggers of any recorded relationship whose child table or
  referenced table no longer exists, and logs a WARN naming them.

### 4. Generate Dynamic Models
```powershell
# Update the catalog and export model types
$types = Export-DynamicModelsFromCatalog -Database .\myapp.db

# Create PowerShell classes from the models
Set-DynamicORMClass
```
- `Export-DynamicModelsFromCatalog` returns a fresh `table -> type name` hashtable for that database only. Models are
  registered per database, so two databases that share a table name keep their own columns and associations.
- Type names: simple table names (letters, digits, single underscores) become `Dynamic` + PascalCase
  (`assets` -> `DynamicAssets`, `user_assets` -> `DynamicUserAssets`). Any other name gets a short hash suffix
  (`user-assets` -> `DynamicUserAssets_7f06a4e6`), and so does a second database or table whose derived name is already
  taken in the session. A generated type is never named after an existing type such as `DynamicActiveRecord`.
- Column accessors: every non-`id` column gets `$rec.<name>()` / `$rec.<name>($value)` accessors. Names that are not
  valid identifiers are sanitized (`first name` -> `first_name`), colliding sanitized names are numbered
  (`a b` / `a_b` -> `a_b` / `a_b_2`), and a column named after a base member or a PowerShell keyword
  (`Save`, `Delete`, `Where`, `class`, ...) is exposed as `Col_<name>()` so `Save()`/`Delete()` keep working.
  `GetAttribute('<column>')` / `SetAttribute('<column>', $value)` always use the raw column name.
- Generated class files are written to a per-session directory under `$env:TEMP` (`PSCsvSQLiteORM_<pid>_<id>`)
  and removed when the module is unloaded. `Set-DynamicORMClass` loads each file once, keeps going past a file that
  is missing or fails to parse, and then throws one error listing every file it could not load.
- A generated class is only resolvable by name inside the module scope that loaded it, so `New-Object DynamicAssets`
  or `[DynamicAssets]::new(...)` fails in your script. `Set-DynamicORMClass` captures each `[type]` as it loads the
  file; use `New-DynamicRecord -Table <table> -Database <db>` to construct instances (it loads the classes first if
  that has not happened yet). Records reached through `GetHasMany()` / `GetBelongsTo()` are created from the same
  captured types.

### 5. Query Your Data
```powershell
# Create a query builder instance
$query = New-DbQuery -Database .\myapp.db -From 'assets'

# Add conditions (named parameters) and execute
$results = $query.Where('hostname = @host', @{ host = 'server01' }).Run()

# Or join related data with an explicit ON clause: Join(<table>, <on>, <Inner|Left|Right|Full>)
$query = New-DbQuery -Database .\myapp.db -From 'assets'
$results = $query.Join('vulns', 'vulns.asset_id = assets.id', 'Left').Select(@('assets.*', 'vulns.title AS vuln_title')).Run()

# Join(<table>, <on>) is an INNER join; Join(<table>) is an INNER join on the catalog relationship ('Auto')
$query = New-DbQuery -Database .\myapp.db -From 'assets'
$results = $query.Join('vulns', 'vulns.asset_id = assets.id').Select(@('assets.hostname', 'vulns.title')).Run()

# Join(<table>, 'Auto', <type>, <foreign key>) picks the foreign key when a table has several to one parent
$query = New-DbQuery -Database .\myapp.db -From 'vulns'
$results = $query.Join('assets', 'Auto', 'Inner', 'asset_id').Select(@('vulns.title', 'assets.hostname')).Run()

# Order, page and let the catalog supply the ON clause ('Auto' uses the relationship confirmed in step 3)
$query = New-DbQuery -Database .\myapp.db -From 'vulns v'
$results = $query.Join('assets a', 'Auto', 'Inner').Select(@('v.*', 'a.hostname')).OrderBy('v.id DESC').Limit(2).Offset(1).Run()
```

Notes on the query builder:
- `Run()` always returns an array, empty when nothing matches, so `@($q.Run()).Count` is the row count and a
  `foreach` over the result runs zero times. This matches `Where()` / `GetHasMany()` on records.
- Each `Where()` clause is wrapped in parentheses before the clauses are joined with `AND`, so an `OR` inside one
  clause cannot change the meaning of the others.
- The `Join()` overloads are `Join(<table>)`, `Join(<table>, <on>)`, `Join(<table>, <on>, <type>)` and
  `Join(<table>, <on>, <type>, <foreign key column>)`. The fourth argument names the foreign key an `Auto`
  join must use and is valid only when the ON argument is the literal `'Auto'`; next to a real ON clause it
  throws `The ForeignKey argument of Join() applies to an 'Auto' join only; ...`.
- An `Auto` join throws when the `__fks__` catalog holds more than one relationship of **equal rank** between
  the same pair of tables (for example `tickets.created_by` and `tickets.assigned_to` both confirmed against
  `users`). The message names the candidates:
  `Auto join between <a> and <b> is ambiguous: <n> relationships of equal rank match (...). Pass an explicit ON clause, or name the foreign-key column with Join(<table>, 'Auto', <type>, <column>).`
  Pass an ON clause or the foreign key argument. A weaker candidate (unconfirmed, or lower confidence) is a
  deterministic loser and is not ambiguous.
- Table references passed to `New-DbQuery -From` and `Join()` may carry an alias (`'assets a'` or `'assets AS a'`);
  `Auto` joins qualify the ON clause with the alias when one is given. They are identifiers, not SQL: an unquoted
  name or alias may only contain word characters and dots (double-quote a name that needs anything else, dashes
  included), and any other text (`'a; DROP TABLE b'`, `'a--'`) is rejected. That rule is deliberately stricter
  than the one for column and table names in step 3, because a reference is pasted into the SQL as written.
  `Select()`, `Where()`, `OrderBy()` and the `ON` clause are raw SQL fragments; bind user input through the
  `Where()` parameter hashtable rather than concatenating it.
- `Right` and `Full` joins are emulated (SQLite versions before 3.39 have no native support). The `Full` emulation
  is `LEFT JOIN ... UNION ALL` the unmatched rows of the swapped `LEFT JOIN`, so duplicate rows are preserved.
  `ORDER BY` on a `Full` join must use result column names (aliases from `Select()`), as SQLite requires for
  compound selects.
- The `Full` emulation identifies unmatched rows through the `rowid` of the `From` table, so that table must
  be an ordinary rowid table. A view or a `WITHOUT ROWID` table is rejected with
  `A Full join requires a rowid table as its From source; '<name>' is a view.` (or `... is declared WITHOUT ROWID`)
  instead of returning a different wrong answer on each SQLite version. Two cases are not checked and fall
  through to SQLite: a schema-qualified source (`'other.t'`) and a source that is not listed in
  `sqlite_master`, such as a temporary table.
- Without a `Select()`, a `Right` or `Full` join projects `<From table>.*, <join table>.*` - the `From`
  table's columns first, the same order an `Inner` or `Left` join gives. Duplicate column names are still
  disambiguated by the driver, so a second `id` arrives as `id1`.

### 6. Work with Dynamic Models
```powershell
# Get a record object for a table (after Export-DynamicModelsFromCatalog / Set-DynamicORMClass)
$asset = New-DynamicRecord -Table 'assets' -Database .\myapp.db

# Create a new row: set column values through the generated accessors, then Save()
$asset.hostname('server04')
$asset.ip('192.168.1.13')
$asset.Save()
$asset.Id            # id assigned by SQLite

# Find and update an existing row
$found = $asset.FindById(1)
$found.ip('10.0.0.1')
$found.Save()

# Query rows and navigate the relationships confirmed in step 3 (Confirm-DbForeignKey)
$rows = $asset.Where('ip LIKE @net', @{ net = '192.168.%' })
$vulns = $found.GetHasMany('vulns')       # DynamicVulns records
$owner = $vulns[0].GetBelongsTo('assets')  # back to the DynamicAssets record

# A table with several foreign keys to the same parent (tickets.created_by and tickets.assigned_to -> users)
# keeps one association per column; pick it by foreign key. The one-argument form uses the first column
# (alphabetical when read from the catalog). $ticket and $user stand for records of those two tables.
$creator  = $ticket.GetBelongsTo('users', 'created_by')
$assigned = $user.GetHasMany('tickets', 'assigned_to')

# All() returns records; AllRows() returns the same rows as plain objects with no record API
$records = $asset.All()
$plain = $asset.AllRows()

# Delete a row (the one saved above, which has no child rows)
$asset.Delete()
```
- `All()` returns records of the same type as `Where()`, `First()` and `FindById()`, so every row has `.Id`,
  `GetHasMany()` / `GetBelongsTo()`, `Save()` and `Delete()`. Reach a column with
  `$rec.<name>()` or `$rec.GetAttribute('<column>')`. **This changed in 3.2.0**: `All()` used to return plain
  `[PSCustomObject]` rows whose properties were the table columns. Code that did
  `$rec.All() | Select-Object name` must now use `$rec.AllRows()`, which keeps that older projection, or
  `$rec.All() | ForEach-Object { $_.GetAttribute('name') }`.
- A relationship may point at a column other than `id`. `HasMany()` and `BelongsTo()` take an optional third
  argument, the column the foreign key references on the parent table: `$rec.HasMany('branch', 'corp_code', 'code')`
  and `$rec.BelongsTo('corp', 'corp_code', 'code')`. Omitting it means `id`, which is what earlier versions
  always used. Models generated in step 4 carry the referenced column of every catalogued relationship, so
  after `Confirm-DbForeignKey -From branch -Column corp_code -To corp -RefColumn code`,
  `GetHasMany('branch')` and `GetBelongsTo('corp')` navigate through `corp.code`.

### 7. Upserts and Tables Without an `id` Column
```powershell
# Insert or update by key column(s); a UNIQUE index on the key columns is created if missing
$asset.InsertOnConflict(@{ hostname = 'server01'; ip = '10.0.0.1' }, @('hostname'), $null)
$asset.BulkUpsert(@(@{ hostname = 'a'; ip = '1' }, @{ hostname = 'b'; ip = '2' }), @('hostname'))
# Explicit UpdateSet: a row-column reference, a bound literal value, and a raw SQL expression
$asset.InsertOnConflict(@{ hostname = 'server01'; ip = '10.0.0.2' }, @('hostname'), @{ ip = 'excluded.ip' })
$asset.InsertOnConflict(@{ hostname = 'server01'; ip = '10.0.0.2' }, @('hostname'), @{ ip = 'fixed literal' })
$asset.InsertOnConflict(@{ hostname = 'server01'; ip = '10.0.0.2' }, @('hostname'), @{ ip = @{ Sql = "excluded.ip || '-x'" } })
# Bulk rows may be hashtables or objects with properties (Import-Csv output, [pscustomobject])
$asset.InsertMany(@([pscustomobject]@{ hostname = 'c'; ip = '3' }))
```
- On SQLite 3.24+ (PowerShell 7 with PSSQLite) the native `INSERT ... ON CONFLICT DO UPDATE` statement is used.
- On older engines (Windows PowerShell 5.1 with PSSQLite ships SQLite 3.8.8.3) the same result is produced with
  `UPDATE ... WHERE <keys>` followed by `INSERT ... WHERE NOT EXISTS`.
- An explicit `UpdateSet` (third argument of `InsertOnConflict`) maps column names to values. Values are bound as
  parameters, never interpolated, except for two forms: the strings `'excluded.<column>'` and `'@<column>'` refer to
  the proposed value of that row column (on both paths), and `@{ Sql = '<expression>' }` injects a raw SQL expression
  (which may itself use `excluded.<column>` or `@<column>`). An empty `UpdateSet` (`@{}`) means "insert or do
  nothing". See the examples in the block above.
- `InsertMany()` and `BulkUpsert()` accept hashtables as well as objects with properties (the output of
  `Import-Csv`, `Select-Object` or `[pscustomobject]@{...}`); every row must supply at least one column.
- A failed `BulkUpsert` rolls back its transaction and rethrows the original error.
- Record keys (`Id`, `FindById()`) are 64-bit, matching SQLite's rowid range.
- Tables without an `id` column (for example a CSV imported without an `id` header) use SQLite's `rowid` as the
  record key: `Where()`, `First()` and `FindById()` expose it as `Id`, and `Save()`/`Delete()` update or delete
  that row instead of inserting a duplicate.
- Column names that are not valid SQL parameter names (for example `First Name` or `Last-Name`) work with
  `Save()`, `InsertMany()`, `InsertOnConflict()` and `BulkUpsert()`: values are bound under positional parameter
  names internally.
- `First()` without an argument orders by `id ASC`; `First('<column> DESC')` orders explicitly.

### 8. Validation and Callbacks
```powershell
$asset.AddValidator('hostname', 'Required', $null)
$asset.On('BeforeSave', { param($record) if ($record.GetAttribute('ip') -eq '0.0.0.0') { throw 'ip not allowed' } })
$asset.On('AfterSave', { param($record) Write-Host "saved $($record.Id)" })
```
- `BeforeSave` and `BeforeDelete` run before any SQL. If they throw, the exception reaches the caller and nothing
  is written or deleted.
- `AfterSave` and `AfterDelete` run only after the SQL succeeded; an exception thrown by one of them is logged and
  not propagated. `Delete()` on a record that was never saved (`Id` is 0) is a no-op and fires no callbacks.

### 9. Transactions, Raw SQL and Maintenance
```powershell
# Every statement for one database goes through one pooled connection, so an open transaction takes in
# every later write on that database until it is completed
$tx = Start-DbTransaction -Database .\myapp.db
Test-DbTransaction -Database .\myapp.db
Complete-DbTransaction -Database .\myapp.db -Transaction $tx

# Complete and Undo also accept -Database alone, to finish a transaction whose handle the script has lost
Start-DbTransaction -Database .\myapp.db | Out-Null
Undo-DbTransaction -Database .\myapp.db

# Raw SQL: parameters are bound, never interpolated. -Scalar returns the first cell
Invoke-DbQuery -Database .\myapp.db -Query 'SELECT COUNT(*) AS c FROM assets' -Scalar

# Drop a relationship and its triggers before dropping a table that takes part in it
Remove-DbForeignKey -Database .\myapp.db -From vulns -Column asset_id

# Release the file when the script is finished with it
Close-DbConnections
```
- `Test-DbTransaction -Database <path>` returns `$true` while the pooled connection for that database is
  inside a transaction. It returns `$false` when no connection is pooled and never opens one.
- `Complete-DbTransaction` and `Undo-DbTransaction` may be called with `-Database` alone: `Complete` commits
  the transaction the module started for that database, `Undo` rolls back whatever transaction is still open
  on its pooled connection. That is the supported way to recover when the handle from `Start-DbTransaction`
  has been lost. Passing `-Transaction $null` explicitly (what the PSSQLite fallback path returns) is a
  no-op, as before. A nested `Start-DbTransaction` is allowed; the outermost handle is the one that commits.
- `Close-DbConnections` and `Initialize-ORMVars` roll back an uncommitted transaction explicitly and warn
  (`PSCsvSQLiteORM: rolling back an uncommitted transaction on '<db>' ...`) instead of discarding the writes
  in silence. The same warning appears on `Remove-Module` / `Import-Module -Force` through the module's
  OnRemove handler. `Close-DbConnections` takes no arguments but is an advanced function, so
  `-WarningAction` and `-WarningVariable` work on it.
- `Invoke-DbQuery -Scalar` returns `$null` both when the result set is empty and when the selected cell is
  SQL NULL; it does not return `[System.DBNull]::Value`, so `$null -eq $result` is the right guard.
- A string bound through `-SqlParameters` must not contain a NUL character (U+0000). SQLite marshals text
  parameters as NUL-terminated UTF-8, so such a value would be stored truncated; the call throws instead,
  naming the parameter and the index of the NUL. To store bytes that may contain zeros, pass a `[byte[]]`
  so the value is bound as a BLOB.
- `Remove-DbForeignKey -Database <db> -From <table> -Column <column>` drops the three triggers of a
  relationship created by `Confirm-DbForeignKey` (including the ON DELETE trigger that lives on the parent
  table), deletes its `__fks__` row and returns the names of the triggers it dropped. Removing a
  relationship that is not there is not an error. Call it **before** dropping a table that takes part in a
  confirmed relationship: SQLite drops a trigger only together with the table the trigger is defined on, so
  the parent's trigger would otherwise survive its child table and break every later DELETE on the parent.
  It supports `-WhatIf` and `-Confirm`.