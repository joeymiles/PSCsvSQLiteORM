# PSCsvSQLiteORM review and repair, September 2026

Branch `fix/code-review-2026-09`, 58 commits on top of upstream `c77be55` (v3.1.3), released as **3.2.0**.

## Outcome

| | Before | After |
|---|---|---|
| Pester tests | 26 functional-only (the real container failed to load on 5.1) | 455 |
| Suite on Windows PowerShell 5.1 | 1 container failed to discover | all pass |
| Suite on PowerShell 7 | 30 pass | all pass |
| Exported functions | 26 | 29 |
| Defects fixed | | 107 |

The dynamic model layer, the whole documented class-based workflow, did not work on either host before this branch. On Windows PowerShell 5.1, the module's own declared target, it also ran with no pooled connection, no working transactions, and SQL errors that printed and let execution continue.

## How the work was done

Three rounds, each with independent verification:

1. **Static review.** Six lens-specific finders (5.1 semantics, SQL correctness, the ORM lifecycle, CSV import, build and docs, resource lifecycle), deduplicated into 80 canonical defects.
2. **Fix round one.** Two workers in separate git worktrees, 31 tasks, each task verified by an agent that rebuilt the module, reran both suites, wrote its own reproduction, and checked the regression tests actually failed on the pre-fix commit. Six tasks were vetoed and redone.
3. **End-to-end round.** Four explorers drove the fixed build through 696 scenario steps on both hosts: the documentation walkthrough, a realistic three-table relational workflow, hostile CSV data, and session lifecycle. 31 further defects confirmed, including one introduced by round one.
4. **Fix round two** (27 defects) **and a documentation pass**, same verify-with-veto structure. Two more vetoes, both catching regressions the fixes themselves had introduced.

Every fix carries at least one regression test tagged with its defect id.

## The defects that mattered most

**Dynamic models were unusable.** `Set-DynamicORMClass` dot-sourced generated class files inside the module's own scope, so `New-Object DynamicAssets` failed in the caller's script and the type registry was always empty. PowerShell cannot make a runtime-generated class name resolvable to a caller, so the fix captures each `[type]` object as the file loads and adds `New-DynamicRecord -Table <t> -Database <db>` as the construction path.

**PowerShell 5.1 ran without transactions or errors.** `Add-Type -AssemblyName System.Data.SQLite` cannot find the assembly on 5.1 even though the required PSSQLite module has already loaded it. The catch cached a null connection forever, so every query opened its own connection, `Start-DbTransaction` returned nothing, failed migrations left their tables behind, and constraint violations printed an error and carried on. Detecting the already-loaded type instead fixes all of it.

**Silent data corruption on import.** Parameter names were derived from column names, so headers `a b`, `a_b` and `a-b` all became `@a_b` and every one of those columns received the last value. Numeric inference turned `02134` into `2134`. A single cell reading `Y` retyped an entire text column to boolean.

**A rollback that was not there.** Round one added table rebuilding to widen a column type. It ran `BEGIN`, `DROP TABLE`, and `COMMIT` in one batch with no `ROLLBACK`, and missed foreign-key triggers living on the parent table. On PowerShell 7 the rebuild aborted after the drop, leaving the connection in a dead transaction where every later write reported success and was discarded. End-to-end testing caught it; the first fix then broke caller-owned transactions and the verifier caught that too. It now nests in a savepoint.

**Foreign keys that did not enforce.** `-OnDelete RESTRICT`, `NO ACTION` and `SET NULL` created no delete-time trigger at all, so only `CASCADE` did anything. Trigger names were built by string concatenation, so a second relationship could silently drop the first one's triggers.

**Documentation described an API that never existed.** The README's model section used `New-DynamicModel -Type`, `[Asset]::Find(1)` and property assignment, none of which are real. Both documents are now executed by the test suite line by line.

## Deliberately not fixed

Eleven items were design decisions or feature requests rather than defects, and are listed here rather than changed: savepoint semantics for nested `Start-DbTransaction`, validators not carrying to loaded records, `-BatchSize` only affecting progress output, the unused `-ForeignKeys` parameter, the stored-but-unused `DbPath` setting, `Add-DbMigration -Down` being accepted and discarded, unpopulated catalog sample columns, and comment-based help coverage.

## Verifying this branch

```powershell
pwsh -NoProfile -File .\build-module.ps1
Invoke-Pester -Path .\Tests
```

Run it under both `powershell.exe` and `pwsh`; the suite is expected to pass on both. Nothing has been pushed to any remote.
