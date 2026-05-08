# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A household account book ("kakeibo") iPad app, delivered in two parallel forms that
build from a **single set of Swift sources**:

- `Omoikane.swiftpm/` — Swift Playground app package (opens in Xcode or Swift Playgrounds on iPad)
- `OmoikaneApp.xcodeproj/` — traditional Xcode iOS app project (references the same files via `SOURCE_ROOT` paths into `Omoikane.swiftpm/`)

There is **no** `OmoikaneApp/<sources>/` directory; the Xcode project does not duplicate code. Only `OmoikaneApp/Assets.xcassets/` lives outside `Omoikane.swiftpm/`.

## Implementation rules

Strictly conform to native API in the implementation, especially in UI implementation. If custom implementation is truly unavoidable, explicitly confirm with the user.

## Common commands

iPad simulator UDID is needed for `-destination`. List with:

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

- `transactions` — append-heavy fact table. Money in **minor units** as `Int64`
  (yen as integer; multiply by 100 for currencies with sub-units). Two derived
  columns `occurred_on` (days-since-1970-01-01 in user's local calendar) and
  `year_month` (YYYYMM as Int) are denormalized so range scans don't touch a
  date function. Indexes for the common query shapes:
  `(occurred_on)`, `(year_month)`, `(category_id, year_month)`,
  `(account_id, year_month)`, `(kind, year_month)`.
- `categories`, `accounts` — dimension tables.
- `monthly_summaries` — `WITHOUT ROWID` table keyed by
  `(year_month, category_id, account_id, kind)` with `total_amount_minor` and
  `transaction_count`. **Maintained by triggers**, not by application code.
- `Schema.rebuildSummaries(_:)` — recompute the summary table from scratch.
  Exposed in Settings as a self-heal / sanity check.

### Layered modules

```
Database.swift            sqlite3 wrapper, WAL/pragmas, prepared statements
Schema.swift              DDL + triggers + migrations
*Store.swift              CRUD per table; SummaryStore reads monthly_summaries
SeedData.swift            first-launch defaults + sample transactions
AppState.swift            @Observable; owns DB + stores; bumps `dataVersion`
ContentView.swift         multi-tab root (Dashboard / Transactions / Reports / Manage / Settings)
```

Views observe `app.dataVersion` via `.task(id: app.dataVersion)` to refetch.
Mutating helpers on `AppState` serialize through `db.sync { … }` and bump
`dataVersion` on success.

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
- **Adding a column to `transactions`** → write a `migrateToV2` in
  `Schema.swift`, bump `latestVersion`, and update both insert/update bind
  sites in `TransactionStore`.
- **Adding a new tab** → add a case to `ContentView.Tab`, a `NavigationStack`
  branch, and the view file.
