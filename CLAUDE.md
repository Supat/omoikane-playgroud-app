# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A household account book ("kakeibo") app for iPad and iPhone, built as a
single Xcode project with two targets: `Omoikane` (iOS; sources, assets,
icon and entitlements under `Omoikane/`) and `OmoikaneWatch` (a standalone
watchOS capture app under `OmoikaneWatch/`, sharing `Omoikane/Shared/` and
`Omoikane/Models/Money.swift`). `Omoikane.xcodeproj/` references files
explicitly (`SOURCE_ROOT` paths), not through a synchronized folder.

The Swift Playground package that used to sit beside the project was
dropped on 2026-10-16. Do not recreate `Package.swift` or reason about
Swift Playgrounds limits; capabilities go in `Omoikane/Omoikane.entitlements`.

When you add a Swift file under `Omoikane/`, also add a `PBXFileReference` +
`PBXBuildFile` for it in `project.pbxproj`, or it silently won't compile.

## Implementation rules

Strictly conform to native API in the implementation, especially in UI implementation. If custom implementation is truly unavoidable, explicitly confirm with the user.

Keyboard navigation support is top priority, consider it for all implementation.

Implementation target for the most recent iPadOS, iOS, macOS. No need to consider backward compatibility with the older version. Deployment target is iOS 26; build against the newest installed simulator runtime.

## Common commands

iPad simulator UDID is needed for `-destination`. The simulator's OS must be ≥ 26 or the build fails with a deployment-target mismatch. List candidates with:

```sh
xcrun simctl list devices available | grep iPad
```

Build:

```sh
xcodebuild -project Omoikane.xcodeproj \
  -scheme Omoikane \
  -destination 'platform=iOS Simulator,id=<udid>' build
```

Build the Watch app (no scheme is checked in; build the target):

```sh
xcodebuild -project Omoikane.xcodeproj -target OmoikaneWatch \
  -sdk watchsimulator -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Notes on tooling oddities:
- Gate commits on `set -o pipefail; xcodebuild … | grep -q 'BUILD SUCCEEDED'`; grep-filtered pipelines otherwise hide failures.
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
3. **Zero dependencies.** Nothing to resolve, nothing to update; a plain
   with no Git URLs to fetch.

### Schema (`Omoikane/Database/Schema.swift`)

`Schema.latestVersion` is **13**. Migrations are applied in order by `Schema.migrate`, each in its own transaction, tracked in `schema_version`.

- `transactions` — append-heavy fact table. Money in **minor units** as `Int64`
  (yen as integer; multiply by 100 for currencies with sub-units). Derived
  columns `occurred_on` (days-since-1970-01-01 in user's local calendar),
  `occurred_at` (Unix seconds, V4, gives stable sub-day ordering) and
  `year_month` (YYYYMM as Int) are denormalized so range scans don't touch a
  date function. Each row carries its `currency` (V2) and, for transfers,
  `counterparty_amount_minor`. Per-leg clearing columns (V3):
  `cleared_at` / `statement_id` for the row's own account, and
  `counterparty_cleared_at` / `counterparty_statement_id` for the transfer
  to-account leg. `split_group` (V5): rows sharing a non-null value are one
  logical transaction split across categories; each row keeps its own
  amount, so nothing else cares. Only the importer writes it so far.
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
- V6 (the rest of Money Pro's model, minimal): `payees` +
  `transactions.payee_id`; `transactions.loan_role` (legacy, always NULL
  since V10: loans are liability accounts now; the column and the model
  field stay so old rows still read);
  `categories.budget_minor` (monthly, home currency; a parent counts
  `max(own, Σ sub-category budgets)` via `effectiveBudgetMinor(in:)`, so
  setting an umbrella figure never shrinks the total; for income categories it is a monthly income target, shown
  green when reached rather than red when exceeded); `categories.color`
  is a "#RRGGBB" set on parent categories only, inherited by children
  (`LedgerCategory.displayColor(in:)`), used for row glyphs, glyph tiles,
  Dashboard budget bars and the stacked budget-composition bar; `accounts.credit_limit_minor`; `schedules` (recurring
  templates, `next_due` is a day key, `ScheduleStore.postDue` inserts real
  rows and advances it; runs at launch and on scene activation).
- V7: `transactions.is_essential` — user-set flag for unavoidable spending.
  Expense only in the UI; not in `monthly_summaries`. The Dashboard reads it
  straight from the fact table for the month.
- V8: `schedules.is_essential` — posted rows inherit it.
- V9: `schedules.day_of_month` anchors monthly/yearly cadence (no drift to the 28th); fixes V4's UTC-midnight `occurred_at` backfill to local midnight. `TransactionStore.update` keeps the stored day key when the instant is unchanged, so a time-zone change cannot move rows.
- V10: `accounts.kind` adds `asset` and `liability` (table rebuilt to widen
  the CHECK; FK pragma toggled around that one migration). Money Pro's
  Asset Purchase / Asset Sale / Liability Acquisition / Discharge of
  Liability are **not** transaction kinds: they are plain transfers to or
  from an asset/liability account, so reports never count a loan
  repayment as spending. `AccountKind.isDebt` (credit + liability) drives
  every sign flip (balance owed is stored negative); `displayGroup` /
  `[Account].displayGroups()` drive the four sections (Payment Accounts,
  Credit Cards, Assets, Liabilities) on Accounts, Transactions and in
  account pickers. The entry form adds for transfers: an
  Interest amount + category when the target is a liability (an expense
  row sharing the transfer's `split_group`, so the form edits both from
  either row and delete takes both; the importer links a discharge's
  interest the same way) and, new entries only, a "Sold entirely" toggle when the
  source is an asset (`adjustBalance(…, to: 0, on:)` writes the rest off
  under Balance adjustment). The Accounts tab shows a home-currency net
  worth and per-group totals.
- V11: `schedules.interest_minor` + `interest_category_id`. A scheduled
  repayment posts the transfer and its interest expense as one split
  group (`ScheduleStore.postDue`), the shape the entry form writes; the
  Repeat picker and the schedule editor both take the interest. Schedule
  rows and the Repeat footer name the role via
  `AccountKind.transferRole(from:to:)`.
- V12: `is_reimbursable` on transactions and schedules, the twin of
  `is_essential` (expense only in the UI, inherited by posted rows, not in
  `monthly_summaries`). Marks spending someone else will pay back.
- V13: iCloud sync bookkeeping. Every table in `SyncStore.tables` gets
  `uuid` (record name on the wire; `rate-<currency>` for rates, random hex
  otherwise, `seed-<table>-<id>` for seed rows so two fresh installs merge)
  and `updated_at` (last-writer-wins clock). Triggers fill both, queue
  inserts/updates in `sync_outbox` and deletes in `sync_tombstones`, and
  are silenced while `sync_flags.applying = 1` (how remote rows are applied
  without echoing). `payees.name` lost its UNIQUE. Stores never touch
  `uuid`/`updated_at`; an explicit `updated_at` change is kept (tests), any
  other UPDATE is stamped now. Tombstones stay 30 days after pushing so a
  stale edit cannot resurrect a deleted row. `sync_state` holds the zone
  change token; `AppState.restore` clears it.
- `Schema.rebuildSummaries(_:)` — recompute the summary table from scratch.
  Exposed in Settings as a self-heal / sanity check.

### Layered modules

```
Database/Database.swift          sqlite3 wrapper, WAL/pragmas, prepared statements
Database/Schema.swift            DDL + triggers + migrations V1–V13
Database/SyncStore.swift         SQLite half of iCloud sync: outbox → records, apply with last-writer-wins, tombstones, change token
Database/TransactionStore.swift  CRUD on transactions
Database/CategoryAccountStore.swift  CRUD on categories + accounts, balances
Database/SummaryStore.swift      reads monthly_summaries for dashboard/reports
Database/StatementStore.swift    statements CRUD + atomic finalize/reopen
Database/CurrencyStore.swift     currency_rates CRUD
Database/PayeeStore.swift        payees CRUD, find-or-create by name
Database/ScheduleStore.swift     schedules CRUD + postDue
Database/MoneyProImport.swift    Money Pro `.back` importer (replaces the ledger; plain SQL over ATTACH)
Database/SeedData.swift          first-launch defaults + sample transactions
Models/Models.swift, Money.swift domain structs, minor-unit money helpers
State/AppState.swift             @Observable; owns DB + stores; bumps `dataVersion`
State/BackupStore.swift          dated SQLite copies in …/Omoikane/Backups (online backup API), auto cadence in UserDefaults
State/CloudSync.swift            CloudKit half of iCloud sync: private zone "Ledger", pull then push, token, silent-push subscription; Watch inbox ingest + snapshot publish
Shared/WatchModels.swift         WatchSnapshot / WatchInboxEntry (Codable, Foundation only); compiled into both targets
OmoikaneWatch/                   OmoikaneWatchApp, WatchStore (CloudKit + disk cache + upload queue), CaptureView
App/Omoikane.swift               WindowGroup, owns tab selection, ⌘1–⌘5 / ⌃Tab commands
Views/ContentView.swift          five-tab root (see below)
```

Views observe `app.dataVersion` via `.task(id: app.dataVersion)` to refetch.
Mutating helpers on `AppState` serialize through `db.sync { … }` and bump
`dataVersion` on success.

### Tabs (`ContentView.swift`, `AppTab`)

| Tab | View | Role |
|---|---|---|
| Dashboard | `DashboardView` + `MonthCalendar` (UICalendarView) | summary cards, essential split, month calendar with daily spend, budgets, charts |
| Accounts | `AccountsView` → `AccountDetailView` → `ReconciliationSheet` | account management, balances, reconciliation statements |
| Transactions | `TransactionsView` | account list → per-account transaction list; landscape split view with inline `TransactionEntryView`, portrait uses the `TransactionEditor` sheet. The entry form handles splits (one row per line, shared `split_group`), payee, asset/liability transfer extras and Repeat (creates a schedule) |
| Reports | `ReportsView` | aggregate queries over `monthly_summaries` |
| Settings | `SettingsView` → `CategoriesView`, `SchedulesView`, `PayeesView`, `BackupsView` | home currency, rates, Manage (Categories and Budget: sub-categories, per-category monthly budgets, an overall monthly spending limit in UserDefaults visualised against the allocated budgets; scheduled transactions; payees), backups (auto/manual/restore/share), iCloud sync (toggle, status, Sync now ⌘⇧S), rebuild summaries, delete all transactions, Money Pro import |

Entity management (add/edit/archive/delete) lives only in its dedicated
surface: Accounts tab, or Settings › Manage for categories, schedules and
payees. Drill-down lists elsewhere are read-only. Five tabs, ⌘1–⌘5.

Keyboard: tab switching is wired in `Omoikane` via `.commands`, not on tab
content (inactive tabs are lazy and their shortcuts never register). Lists use
`List(selection:)` + `.tag` for arrow-key highlight, `onKeyPress(.return)` to
act, `onKeyPress(.escape)` to clear. Rows are plain views with
`.onTapGesture`, **not** `Button` — a Button becomes a focusable child that
swallows arrow keys before the List sees them.

Shortcut vocabulary, keep it consistent: ⌘N new, ⌘F search, ⌘R reconcile
(open the sheet, toggle reconciliation mode, or reopen a statement depending
on the screen), Space ticks the selected row in reconciliation mode,
⌘⇧A archive, ⌘U unarchive, ⌘⌫ delete, ⌘⇧B adjust balance, ⌘0 back to the
current month when Reports is pinned. Every swipe action has one of these
twins, either on the keyboard-selected row or in the entity's detail
surface (account detail screen, category editor sheet). Lists use
`.keyboardListNavigation(selection:onReturn:onDelete:)`; any other hidden
key binding uses `.hiddenShortcut(_:modifiers:role:action:)` (Common.swift).
Budget figures come from `BudgetMath` / `BudgetLine` and are drawn by
`BudgetRowView` and `LimitBar`; the signed-balance rule is
`Transaction.effect(on:)` in Swift and `BalanceSQL` in queries. The delete path
always goes through the shared `*ManagementAlerts` modifier so the
reference-count gate runs no matter where the delete started.

`NumberPadField` is a custom Numbers-style numpad for amount entry (one of
the few deliberate departures from stock controls).

Surfaces: system chrome is Liquid Glass on its own. Every custom panel uses
`.glassCard()` (Common.swift); custom buttons use `.buttonStyle(.glass)` /
`.glassProminent`. No flat `.background(Color…)` or material fills on cards.
Don't wrap scrolling card stacks in `GlassEffectContainer`: it is for glass
shapes that morph into each other, and on a ScrollView of static cards it
logs "glassEffect() tried to update multiple times per frame". Don't put
glass on cells of a scrolling collection (glyph grid, glyph strip) either;
it stutters. Those use a plain `tertiarySystemFill` tile.
Glyphs have titles: `SymbolPicker.title(for:)`; show the title, never the
raw symbol name.

Amounts on screen always go through `Formatters.moneyText(_:currency:)` or
`Text.moneyStyle()` (monospaced face + tabular digits). Don't write a bare
`Text(Formatters.money(...))`. Amount *input* always uses `NumberPadField`,
which is monospaced by default, inserts thousands separators as you type,
caps input at 15 integer + 2 fraction digits, and sizes to the width it is
offered (long values scroll inside). The bound text may contain commas;
`Money.parseMinor` strips them and parses with `Decimal`, never `Double`,
so large amounts keep every digit. Don't add private parse copies.

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
- **Adding a column to `transactions`** → write a `migrateToV14` in
  `Schema.swift`, add the `current < 14` block to `Schema.migrate`, bump
  `latestVersion`, and update both insert/update bind sites in `TransactionStore`.
  If the column feeds `monthly_summaries`, also extend the `WHEN` clause of the
  `tx_au` trigger.
- **iCloud sync** → `CloudSync` runs pull-then-push on launch, on scene
  activation, 3 s after any `bump()` (debounced) and on CloudKit's silent
  push (`AppDelegate` in App/Omoikane.swift). One record per row: type =
  table, name = uuid, fields = columns with foreign keys as uuids and a
  `nulls` list naming NULL columns (absent keys are left alone on apply).
  Push conflicts compare `updated_at` with the server copy. Home currency
  and the spending limit go through `NSUbiquitousKeyValueStore`. Needs the
  iCloud + push entitlements (`Omoikane/Omoikane.entitlements`); the
  toggle defaults to off. `tools/sync-check/main.swift` is a macOS
  harness that syncs two databases through an in-memory zone; run it after
  touching `SyncStore` or the V13 triggers. The triggers only queue rows
  changed after V13, so `SyncStore.queueAll()` queues the whole ledger
  when the toggle is turned on, after a restore and on a zone reset. Adding a synced table: append
  to `SyncStore.tables` in dependency order and give it the V13 treatment
  in a new migration.
- **Apple Watch** → `OmoikaneWatch` is watch-only (`WKWatchOnly`): no
  iPhone app needed, no WatchConnectivity, never touches the ledger. It
  reads one `watch_snapshot` record (JSON: accounts, expense categories,
  this month's spend and limit; published by the iOS app at the end of
  every sync cycle when its content hash changes) and writes one
  `watch_inbox` record per captured expense (JSON, record name = entry
  uuid), both in the same private zone. The iOS `pull()` sees inbox
  records through zone changes, turns each into a transaction with the
  entry's uuid (`WatchInboxEntry.transactionRecord(autoClear:)`, a pure
  function, so two devices ingesting the same entry upsert one row) and
  deletes the inbox record. The Watch caches the snapshot and its queue
  on disk, so it captures offline and uploads later. Expense only, no
  complication yet. Keep the Watch independent of `Models.swift` and
  everything UIKit; add shared types to `Omoikane/Shared/` and list them
  in both targets' Sources phases.
- **Changing the importer** → `tools/moneypro-import/main.swift` is a macOS
  dry run that compiles the app's own `Database`, `Schema`, `SyncStore` and
  `MoneyProImport` sources and runs them against a real `.back` file; the
  compile command is in its header. Run it before and after.
- **Adding a new tab** → add a case to `AppTab`, a `NavigationStack` branch in
  `ContentView`, the view file, and a `⌘N` command in `Omoikane` (App/Omoikane.swift).
