# PSCsvSQLiteORM

PowerShell 5.1 ORM for SQLite with CSV import, schema inference, dynamic models, relationships, joins, upserts, and migrations.

## Quick Start

### 1. Install Dependencies
```powershell
# Install required PSSQLite module
Install-Module PSSQLite -Scope CurrentUser

# Install PSCsvSQLiteORM from PowerShell Gallery (latest version)
Install-Module PSCsvSQLiteORM -Scope CurrentUser

# Or install specific version 3.1.3
Install-Module PSCsvSQLiteORM -RequiredVersion 3.1.3 -Scope CurrentUser
```

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
  inserts the rows.
- `Strict`: creates the table when it is missing but never alters an existing one; a CSV header that is not a
  column of the table throws `Strict mode: missing column <name> in <table>` before any row is inserted.
- `AppendOnly`: only inserts rows. The table must already exist (a fresh database throws
  `AppendOnly mode: table '<table>' does not exist.`) and its schema is never changed, so use it for the second and
  later loads of a table, never for the first.

Every mode appends rows; nothing is deleted or replaced. An `id` header becomes `INTEGER PRIMARY KEY AUTOINCREMENT`,
so importing a file whose ids are already in the table fails with a UNIQUE constraint error.

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

# Order, page and let the catalog supply the ON clause ('Auto' uses the relationship confirmed in step 3)
$query = New-DbQuery -Database .\myapp.db -From 'vulns v'
$results = $query.Join('assets a', 'Auto', 'Inner').Select(@('v.*', 'a.hostname')).OrderBy('v.id DESC').Limit(2).Offset(1).Run()
```

Notes on the query builder:
- Each `Where()` clause is wrapped in parentheses before the clauses are joined with `AND`, so an `OR` inside one
  clause cannot change the meaning of the others.
- Table references passed to `New-DbQuery -From` and `Join()` may carry an alias (`'assets a'` or `'assets AS a'`);
  `Auto` joins qualify the ON clause with the alias when one is given. They are identifiers, not SQL: an unquoted
  name or alias may only contain word characters and dots (double-quote a name that needs anything else, dashes
  included), and any other text (`'a; DROP TABLE b'`, `'a--'`) is rejected. `Select()`, `Where()`, `OrderBy()` and the `ON` clause are
  raw SQL fragments; bind user input through the `Where()` parameter hashtable rather than concatenating it.
- `Right` and `Full` joins are emulated (SQLite versions before 3.39 have no native support). The `Full` emulation
  is `LEFT JOIN ... UNION ALL` the unmatched rows of the swapped `LEFT JOIN`, so duplicate rows are preserved; it
  relies on the `rowid` of the `From` table, so that table must not be `WITHOUT ROWID` or a view. `ORDER BY` on a
  `Full` join must use result column names (aliases from `Select()`), as SQLite requires for compound selects.

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

# Delete a row (the one saved above, which has no child rows)
$asset.Delete()
```

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