# Changelog

## v3.2.0

29 exported commands, up from 26 in v3.1.3.

### New commands

- `New-DynamicRecord` constructs a record of a generated model. A generated class is only resolvable by name
  inside the module scope that loaded it, so this is the supported way to reach one from a script.
- `Remove-DbForeignKey` drops the triggers and the catalog row of a relationship created by
  `Confirm-DbForeignKey`.
- `Test-DbTransaction` reports whether the pooled connection for a database is inside a transaction.

### Breaking changes

- `All()` now returns records, the same type as `Where()`, `First()` and `FindById()`, so every row can
  navigate relationships and be saved. The previous plain-object projection is now `AllRows()`. Code that did
  `$rec.All() | Select-Object name` must use `$rec.AllRows()`, or
  `$rec.All() | ForEach-Object { $_.GetAttribute('name') }`.
- `Confirm-DbForeignKey` refuses to record a relationship that the child table's rows already violate. Pass
  `-Force` to record it and enforce it for future writes only. This affects the documented "import the CSVs
  first, then confirm" workflow when the imported data is not clean.
- `Import-CsvToSqlite` trims `-TableName` the way it already trimmed headers. A table created by an earlier
  version under a padded name is not found by the trimmed spelling.
- `Invoke-DbQuery -Scalar` returns `$null` for a SQL NULL cell instead of `[System.DBNull]::Value`. A guard
  written as `$result -is [System.DBNull]` no longer fires; use `$null -eq $result`.
- Table and column names may now contain any character except control characters. Names that an earlier
  version rejected are accepted.

### Records and relationships

- `HasMany()`, `BelongsTo()` and the generated model files carry the referenced column of a relationship, so
  `Confirm-DbForeignKey -RefColumn` navigates through a column other than `id`.
- A table with several foreign keys to the same parent keeps one association per column, selected with the
  second argument of `GetHasMany()` / `GetBelongsTo()`.
- `Confirm-DbForeignKey` triggers carry an ownership marker and take a hashed name when the derived one is
  already taken, and `Update-DbCatalog` drops the triggers of a relationship whose child or referenced table
  is gone.
- Every `-OnDelete` mode is enforced, not only `CASCADE`.
- Tables without an `id` column use SQLite's `rowid` as the record key.
- Record keys are 64-bit.

### Query builder

- `Join(<table>, <on>, <type>, <foreign key>)` picks the foreign key of an `Auto` join; an `Auto` join throws
  when the catalog holds more than one relationship of equal rank between the two tables.
- A `Full` join whose `From` source is a view or a `WITHOUT ROWID` table throws instead of returning a
  different wrong answer per SQLite version. `Right` and `Full` joins without `Select()` project the `From`
  table's columns first.
- `Run()` always returns an array, empty when nothing matches.
- Each `Where()` clause is parenthesised before the clauses are joined with `AND`.
- `OrderBy()`, `Limit()` and `Offset()` are callable; backing properties of the same names used to shadow them.

### CSV import

- Supports `-WhatIf` and `-Confirm`, and rolls back the `CREATE TABLE` and `ALTER TABLE ADD COLUMN` of a
  failed run together with its rows.
- Refuses a CSV wider than 999 columns, or with an empty header name, before anything is created.
- `Relaxed` warns when it changes the declared type of an existing column, and no longer rewrites a numeric
  column to TEXT when the CSV only spells its numbers differently (`10.0` in a REAL column).
- A widening rebuild runs in one transaction and restores the table's indexes and triggers, including
  triggers on other tables, or leaves the database untouched.
- Values are bound under positional parameter names, so columns whose names differ only by punctuation are no
  longer written into one another.
- Numeric type inference no longer strips leading zeros from values such as postcodes, and a column is
  converted to boolean only when the file contains both a true and a false token.
- Null-token matching is case-sensitive by default; `-IgnoreNullTokenCase` restores the old behaviour.

### Queries, identifiers and logging

- A string parameter containing a NUL character (U+0000) is rejected instead of being stored truncated.
- `Write-DbLog -Level` is optional and defaults to INFO; `Set-DbLogging` applies only the parameters supplied.
- `Initialize-ORMVars` takes the settings hashtable out of everything the settings script emits and throws
  when it emits none; a bare call also resets the default database path and every model registration.
- `Close-DbConnections` and `Initialize-ORMVars` roll back an uncommitted transaction with a warning instead
  of discarding its writes in silence; `Complete-DbTransaction` and `Undo-DbTransaction` accept `-Database`
  alone.
- `DynamicActiveRecord` `Save`, `InsertMany`, `InsertOnConflict` and `BulkUpsert` bind every column value
  under a positional parameter name, so record writes work for columns with spaces, dashes or other special
  characters; a failed insert now throws on Windows PowerShell 5.1 as well as on PowerShell 7.
- On Windows PowerShell 5.1 the module now uses a pooled `System.Data.SQLite` connection, so transactions
  work and SQL errors terminate instead of printing and continuing.

### Packaging

- The manifest declares both the Desktop and Core editions and pins PSSQLite 1.1.0 or later.
- `build-module.ps1` fails the build when `docs\` and `source\Examples\` do not reach the built module, which
  now also ships `en-US\about_PSCsvSQLiteORM.help.txt`.
- Documentation is split into a Quick Start (`README.md`) and a reference (`docs/reference.md`), and every
  command and claim in both is executed by the test suite.

## v3.1.3

Sanitized SQL parameter names in `Import-CsvToSqlite` so that column names containing spaces or special
characters no longer broke the insert.
