# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A household account book ("kakeibo") iPad app, delivered in two parallel forms that
build from a **single set of Swift sources**:

- `Omoikane.swiftpm/` — Swift Playground app package (opens in Xcode or Swift Playgrounds on iPad)
- `OmoikaneApp.xcodeproj/` — traditional Xcode iOS app project (references the same files via `SOURCE_ROOT` paths into `Omoikane.swiftpm/`)

There is **no** `OmoikaneApp/<sources>/` directory; the Xcode project does not duplicate code. Only `OmoikaneApp/Assets.xcassets/` lives outside `Omoikane.swiftpm/`.

When you add a Swift file under `Omoikane.swiftpm/`, also add a `PBXFileReference` + `PBXBuildFile` for it in `project.pbxproj`, or the Xcode project silently won't compile it.

## Implementation rules

Strictly conform to native API in the implementation, especially in UI implementation. If custom implementation is truly unavoidable, explicitly confirm with the user.

Keyboard navigation support is top priority, consider it for all implementation.

Implementation target for the most recent iPadOS, iOS, macOS. No need to consider backward compatibility with the older version. Deployment target is iOS 26; build against the newest installed simulator runtime.

## Common commands

iPad simulator UDID is needed for `-destination`. The simulator's OS must be ≥ 26 or the build fails with a deployment-target mismatch. List candidates with:

```sh
xcrun simctl list devices available | grep iPad
```

Build the **Swift Playground app**:

```sh
xcodebuild -workspace Omoikane.swiftpm \
  -scheme Omoikane \
  -destination 'platform=iOS Simulator,id=<udid>' build
```

Build the **Xcode project**:

```sh
xcodebuild -project OmoikaneApp.xcodeproj \
  -scheme OmoikaneApp \
  -destination 'platform=iOS Simulator,id=<udid>' build
```

Notes on tooling oddities:
- `swift package describe` does **not** work on `Omoikane.swiftpm/` because `AppleProductTypes` is only resolvable inside Xcode/Swift Playgrounds. Use `xcodebuild` instead.
- `xcodebuild` treats a `.swiftpm` directory as a **workspace** (`-workspace`), not a project.
- Specify destinations by **UDID**, not by device name — name matching of `iPad Pro (11-inch) (4th generation)` fails in current Xcode.
- The only expected build noise is an `appintentsmetadataprocessor` warning about a missing AppIntents dependency. Anything else is new.

## Architecture

### Why raw SQLite (not SwiftData / Core Data / GRDB)

The brief required *high-volume writes* with *fast aggregate queries on multiple
conditions*. Three reasons we went with raw `import SQLite3`:

1. **Trigger-maintained materialized aggregates.** Every dashboard/report query
   reads from `monthly_summaries`, which is kept in lockstep with the
   `transactions` fact table by `AFTER INSERT/UPDATE/DELETE` triggers. Summary
   queries become O(small index range), regardless of fact-table size.
   SwiftData has no equivalent; Core Data would need manual aggregate maintenance
   and still pays Objective-C bridging.
2. **WAL + tuned pragmas** (`Database.swift::applyPragmas`) — concurrent readers,
   single writer, mmap, page cache, 5s busy timeout. Free with SQLite, harder
   with framework wrappers.
3. **Zero dependencies.** A `.swiftpm` package can run in iPad Swift Playgrounds
   with no Git URLs to fetch.

### Schema (`Omoikane.swiftpm/Database/Schema.swift`)

`Schema.latestVersion` is **4**. Migrations are applied in order by `Schema.migrate`, each in its own transaction, tracked in `schema_version`.

- `transactions` — append-heavy fact table. Money in **minor units** as `Int64`
  (yen as integer; multiply by 100 for currencies with sub-units). Derived
  columns `occurred_on` (days-since-1970-01-01 in user's local calendar),
  `occurred_at` (Unix seconds, V4, gives stable sub-day ordering) and
  `year_month` (YYYYMM as Int) are denormalized so range scans don't touch a
  date function. Each row carries its `currency` (V2) and, for transfers,
  `counterparty_amount_minor`. Per-leg clearing columns (V3):
  `cleared_at` / `statement_id` for the row's own account, and
  `counterparty_cleared_at` / `counterparty_statement_id` for the transfer
  to-account leg.
- `categories`, `accounts` — dimension tables. Both support archiving.
  Accounts carry reconciliation policy: `clears_entries_by_default`
  (cash accounts default to 1) and `statement_closing_day`.
- `monthly_summaries` — `WITHOUT ROWID` table keyed by
  `(year_month, category_id, account_id, currency, kind)` with `total_amount_minor` and
  `transaction_count`. **Maintained by triggers**, not by application code.
  The update trigger only fires when one of those key dimensions or the amount
  changes, so a reconciliation tick (clearing columns only) is cheap.
- `statements` (V3) — one row per reconciliation statement for an account,
  `status` is `open` or `reconciled`. Finalizing stamps the cleared legs on
  transactions and snapshots `cleared_total_minor` / `cleared_count` onto the
  statement as an audit record.
- `currency_rates` (V2) — rate to the home currency for every non-home
  currency. The home currency itself lives in `UserDefaults` via `AppState`.
- `Schema.rebuildSummaries(_:)` — recompute the summary table from scratch.
  Exposed in Settings as a self-heal / sanity check.

### Layered modules

```
Database/Database.swift          sqlite3 wrapper, WAL/pragmas, prepared statements
Database/Schema.swift            DDL + triggers + migrations V1–V4
Database/TransactionStore.swift  CRUD on transactions
Database/CategoryAccountStore.swift  CRUD on categories + accounts, balances
Database/SummaryStore.swift      reads monthly_summaries for dashboard/reports
Database/StatementStore.swift    statements CRUD + atomic finalize/reopen
Database/CurrencyStore.swift     currency_rates CRUD
Database/SeedData.swift          first-launch defaults + sample transactions
Models/Models.swift, Money.swift domain structs, minor-unit money helpers
State/AppState.swift             @Observable; owns DB + stores; bumps `dataVersion`
App/OmoikaneApp.swift            WindowGroup, owns tab selection, ⌘1–⌘6 / ⌃Tab commands
Views/ContentView.swift          six-tab root (see below)
```

Views observe `app.dataVersion` via `.task(id: app.dataVersion)` to refetch.
Mutating helpers on `AppState` serialize through `db.sync { … }` and bump
`dataVersion` on success.

### Tabs (`ContentView.swift`, `AppTab`)

| Tab | View | Role |
|---|---|---|
| Dashboard | `DashboardView` | summary of the current period |
| Accounts | `AccountsView` → `AccountDetailView` → `ReconciliationSheet` | account management, balances, reconciliation statements |
| Transactions | `TransactionsView` | account list → per-account transaction list; landscape split view with inline `TransactionEntryView`, portrait uses the `TransactionEditor` sheet |
| Reports | `ReportsView` | aggregate queries over `monthly_summaries` |
| Categories | `CategoriesView` | expense/income categories with sub-categories |
| Settings | `SettingsView` | home currency, rates, rebuild summaries |

Entity management (add/edit/archive/delete) lives only in its dedicated tab.
Drill-down lists elsewhere are read-only.

Keyboard: tab switching is wired in `OmoikaneApp` via `.commands`, not on tab
content (inactive tabs are lazy and their shortcuts never register). Lists use
`List(selection:)` + `.tag` for arrow-key highlight, `onKeyPress(.return)` to
act, `onKeyPress(.escape)` to clear. Rows are plain views with
`.onTapGesture`, **not** `Button` — a Button becomes a focusable child that
swallows arrow keys before the List sees them.

`NumberPadField` is a custom Numbers-style numpad for amount entry (one of
the few deliberate departures from stock controls).

### Naming gotcha worth knowing

`Foundation` (via the Objective-C runtime bridge) re-exports
`typealias Category = OpaquePointer`. Defining `struct Category` in module scope
silently shadows successfully on a real build but trips SourceKit and produces
confusing `Extra arguments at positions #2…` diagnostics. The model is named
`LedgerCategory` for that reason. `Transaction` does not collide in module scope,
so it stays as-is. If you add new top-level types, sanity-check against
`OpaquePointer` typealiases before naming them.

## Where future changes go

- **Adding a query shape** → extend `SummaryStore`, not the views. If the new
  shape can't be served by `monthly_summaries`, add a covering index on
  `transactions` first; only add a new materialized table if profiling shows
  the index isn't enough.
- **Adding a column to `transactions`** → write a `migrateToV5` in
  `Schema.swift`, add the `current < 5` block to `Schema.migrate`, bump
  `latestVersion`, and update both insert/update bind sites in `TransactionStore`.
  If the column feeds `monthly_summaries`, also extend the `WHEN` clause of the
  `tx_au` trigger.
- **Adding a new tab** → add a case to `AppTab`, a `NavigationStack` branch in
  `ContentView`, the view file, and a `⌘N` command in `OmoikaneApp`.
