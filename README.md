# Omoikane — iPad household account book

Two parallel projects, one shared source tree:

| Form | Where to open |
| --- | --- |
| Swift Playground app | open `Omoikane.swiftpm/` in Xcode (or copy the bundle to an iPad with Swift Playgrounds) |
| Traditional Xcode iOS app | open `OmoikaneApp.xcodeproj/` in Xcode |

The Xcode project does **not** duplicate the Swift sources — its file references
point to `Omoikane.swiftpm/{App,Views,Database,Models,State}/*.swift`. Edit a
file in either place; both targets see the change.

## Tabs

- **Dashboard** — current month at a glance: income / expense / net, last 6 months trend, top categories, account balances.
- **Transactions** — filterable, searchable, swipe-to-delete list. Tap to edit, `+` to add.
- **Reports** — line trend + horizontal bar by category + per-account totals over a 3/6/12/24-month window.
- **Manage** — categories and accounts (with current balances).
- **Settings** — transaction count, default currency, "Rebuild summary cache" timer (handy for showing how fast the summary maintenance is).

## Data model

`transactions` is the append-heavy fact table; `monthly_summaries` is a
trigger-maintained aggregate keyed by `(year_month, category_id, account_id, kind)`.
Every chart and stat in the app queries the aggregate, not the fact table. See
`CLAUDE.md` and `Omoikane.swiftpm/Database/Schema.swift` for the design rationale.

## Building from the command line

```sh
# pick an iPad simulator UDID
xcrun simctl list devices available | grep iPad

# Swift Playground app
xcodebuild -workspace Omoikane.swiftpm -scheme Omoikane \
  -destination 'platform=iOS Simulator,id=<udid>' build

# Xcode project
xcodebuild -project OmoikaneApp.xcodeproj -scheme OmoikaneApp \
  -destination 'platform=iOS Simulator,id=<udid>' build
```

## Requirements

- Xcode 15+ (iOS 17 deployment target — the app uses `@Observable` and `ContentUnavailableView`).
- No third-party dependencies. SQLite is the system one (`-lsqlite3` / `import SQLite3`).
