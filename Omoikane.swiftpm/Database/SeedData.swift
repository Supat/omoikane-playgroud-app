import Foundation

/// Seeds default categories, accounts, and (optionally) sample transactions on
/// first launch. Idempotent: skips if categories already exist.
///
/// Includes one USD account so the multi-currency UI is not invisible on a
/// fresh install — the user sees per-currency dashboard rows immediately.
enum SeedData {
    static func seedIfNeeded(db: Database, homeCurrency: String = "JPY", addSampleTransactions: Bool = true) throws {
        let countStmt = try db.prepare("SELECT COUNT(*) FROM categories;")
        var existing = 0
        if try countStmt.step() { existing = countStmt.int(0) }
        guard existing == 0 else { return }

        let categories = CategoryStore(db: db)
        let accounts = AccountStore(db: db)
        let transactions = TransactionStore(db: db)
        let rates = CurrencyStore(db: db)

        try db.transaction {
            // Default expense categories
            let groceries = try categories.insert(name: "Groceries",       kind: .expense, icon: "cart")
            let dining    = try categories.insert(name: "Dining Out",      kind: .expense, icon: "fork.knife")
            let transport = try categories.insert(name: "Transport",       kind: .expense, icon: "tram.fill")
            let utilities = try categories.insert(name: "Utilities",       kind: .expense, icon: "bolt.fill")
            let rent      = try categories.insert(name: "Rent",            kind: .expense, icon: "house.fill")
            let health    = try categories.insert(name: "Health",          kind: .expense, icon: "cross.case.fill")
            let leisure   = try categories.insert(name: "Leisure",         kind: .expense, icon: "ticket.fill")
            let travel    = try categories.insert(name: "Travel",          kind: .expense, icon: "airplane")
            _ = try categories.insert(name: "Other (expense)",             kind: .expense, icon: "ellipsis.circle")

            // Default income categories
            let salary    = try categories.insert(name: "Salary",          kind: .income,  icon: "yensign.circle.fill")
            _ = try categories.insert(name: "Bonus",                       kind: .income,  icon: "gift.fill")
            _ = try categories.insert(name: "Other (income)",              kind: .income,  icon: "ellipsis.circle")

            // Default accounts — JPY trio plus a USD bank account so the
            // multi-currency UI has something to show on day one.
            let cash       = try accounts.insert(name: "Cash",        kind: .cash,   currency: "JPY", initialBalanceMinor:  30_000)
            let bank       = try accounts.insert(name: "Bank",        kind: .bank,   currency: "JPY", initialBalanceMinor: 500_000)
            let credit     = try accounts.insert(name: "Credit Card", kind: .credit, currency: "JPY", initialBalanceMinor:       0)
            let usdBank    = try accounts.insert(name: "USD Savings", kind: .bank,   currency: "USD", initialBalanceMinor: 200_000) // $2,000.00

            // Seed a JPY↔USD rate against the user's home currency so the
            // dashboard rollup works on first run. We only know two
            // currencies up front (JPY and USD), so we seed whichever is
            // *not* the home currency.
            //   home=JPY → seed USD: 1 USD = 150 JPY
            //   home=USD → seed JPY: 1 JPY ≈ 0.00667 USD
            //   home=anything else → skip; user sets rates manually.
            switch homeCurrency {
            case "JPY": try rates.upsert(currency: "USD", rateToHome: 150.0)
            case "USD": try rates.upsert(currency: "JPY", rateToHome: 1.0 / 150.0)
            default:    break
            }

            guard addSampleTransactions else { return }

            // A few months of sample data so the dashboard shows something.
            let cal = Calendar.current
            let today = Date()
            var samples: [Transaction] = []
            let now = Date()

            for monthsAgo in 0..<3 {
                guard let monthStart = cal.date(byAdding: .month, value: -monthsAgo, to: today) else { continue }

                // JPY: Salary on the 25th
                if let pay = cal.date(bySetting: .day, value: 25, of: monthStart) {
                    samples.append(Transaction(
                        id: 0, occurredOn: pay, amountMinor: 320_000, currency: "JPY",
                        kind: .income, categoryId: salary, accountId: bank,
                        counterpartyAccountId: nil, counterpartyAmountMinor: nil,
                        note: "Monthly salary", tags: [], createdAt: now, updatedAt: now
                    ))
                }
                // JPY: Rent on the 1st
                if let rentDay = cal.date(bySetting: .day, value: 1, of: monthStart) {
                    samples.append(Transaction(
                        id: 0, occurredOn: rentDay, amountMinor: 90_000, currency: "JPY",
                        kind: .expense, categoryId: rent, accountId: bank,
                        counterpartyAccountId: nil, counterpartyAmountMinor: nil,
                        note: "Rent", tags: ["fixed"], createdAt: now, updatedAt: now
                    ))
                }
                // JPY: Utilities mid-month
                if let utilDay = cal.date(bySetting: .day, value: 15, of: monthStart) {
                    samples.append(Transaction(
                        id: 0, occurredOn: utilDay, amountMinor: 12_500, currency: "JPY",
                        kind: .expense, categoryId: utilities, accountId: bank,
                        counterpartyAccountId: nil, counterpartyAmountMinor: nil,
                        note: "Electric + gas", tags: ["fixed"], createdAt: now, updatedAt: now
                    ))
                }

                // JPY: Sprinkle groceries / dining / transport / health / leisure
                let weeklyAmounts: [(Int64, Int64, Int64, Int64)] = [
                    (5_400, 2_300, 760, 800),
                    (6_200, 3_100, 760, 1_200),
                    (4_800, 1_900, 760, 600),
                    (7_100, 4_200, 760, 950),
                ]
                for (idx, weekly) in weeklyAmounts.enumerated() {
                    let day = 4 + idx * 7
                    guard let d = cal.date(bySetting: .day, value: day, of: monthStart) else { continue }
                    samples.append(Transaction(
                        id: 0, occurredOn: d, amountMinor: weekly.0, currency: "JPY",
                        kind: .expense, categoryId: groceries, accountId: cash,
                        counterpartyAccountId: nil, counterpartyAmountMinor: nil,
                        note: "Weekly groceries", tags: [], createdAt: now, updatedAt: now
                    ))
                    samples.append(Transaction(
                        id: 0, occurredOn: d, amountMinor: weekly.1, currency: "JPY",
                        kind: .expense, categoryId: dining, accountId: credit,
                        counterpartyAccountId: nil, counterpartyAmountMinor: nil,
                        note: "Restaurants", tags: [], createdAt: now, updatedAt: now
                    ))
                    samples.append(Transaction(
                        id: 0, occurredOn: d, amountMinor: weekly.2, currency: "JPY",
                        kind: .expense, categoryId: transport, accountId: cash,
                        counterpartyAccountId: nil, counterpartyAmountMinor: nil,
                        note: "Train", tags: [], createdAt: now, updatedAt: now
                    ))
                    if idx == 1 {
                        samples.append(Transaction(
                            id: 0, occurredOn: d, amountMinor: 2_400, currency: "JPY",
                            kind: .expense, categoryId: health, accountId: bank,
                            counterpartyAccountId: nil, counterpartyAmountMinor: nil,
                            note: "Pharmacy", tags: [], createdAt: now, updatedAt: now
                        ))
                    }
                    if idx == 3 {
                        samples.append(Transaction(
                            id: 0, occurredOn: d, amountMinor: 4_500, currency: "JPY",
                            kind: .expense, categoryId: leisure, accountId: credit,
                            counterpartyAccountId: nil, counterpartyAmountMinor: nil,
                            note: "Movie + snacks", tags: [], createdAt: now, updatedAt: now
                        ))
                    }
                }

                // USD: a couple of foreign-currency entries so the dashboard
                // shows a multi-currency rollup.
                if let d = cal.date(bySetting: .day, value: 10, of: monthStart) {
                    samples.append(Transaction(
                        id: 0, occurredOn: d, amountMinor: 4_500, currency: "USD", // $45.00
                        kind: .expense, categoryId: dining, accountId: usdBank,
                        counterpartyAccountId: nil, counterpartyAmountMinor: nil,
                        note: "Coffee meeting", tags: [], createdAt: now, updatedAt: now
                    ))
                }
                if let d = cal.date(bySetting: .day, value: 18, of: monthStart) {
                    samples.append(Transaction(
                        id: 0, occurredOn: d, amountMinor: 12_000, currency: "USD", // $120.00
                        kind: .expense, categoryId: travel, accountId: usdBank,
                        counterpartyAccountId: nil, counterpartyAmountMinor: nil,
                        note: "Flight booking", tags: [], createdAt: now, updatedAt: now
                    ))
                }
            }

            try transactions.bulkInsert(samples)
        }
    }
}
