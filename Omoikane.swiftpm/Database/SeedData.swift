import Foundation

/// Seeds default categories, accounts, and (optionally) sample transactions on
/// first launch. Idempotent: skips if categories already exist.
enum SeedData {
    static func seedIfNeeded(db: Database, addSampleTransactions: Bool = true) throws {
        let countStmt = try db.prepare("SELECT COUNT(*) FROM categories;")
        var existing = 0
        if try countStmt.step() { existing = countStmt.int(0) }
        guard existing == 0 else { return }

        let categories = CategoryStore(db: db)
        let accounts = AccountStore(db: db)
        let transactions = TransactionStore(db: db)

        try db.transaction {
            // Default expense categories
            let groceries  = try categories.insert(name: "Groceries",      kind: .expense, icon: "cart")
            let dining     = try categories.insert(name: "Dining Out",     kind: .expense, icon: "fork.knife")
            let transport  = try categories.insert(name: "Transport",      kind: .expense, icon: "tram.fill")
            let utilities  = try categories.insert(name: "Utilities",      kind: .expense, icon: "bolt.fill")
            let rent       = try categories.insert(name: "Rent",           kind: .expense, icon: "house.fill")
            let health     = try categories.insert(name: "Health",         kind: .expense, icon: "cross.case.fill")
            let leisure    = try categories.insert(name: "Leisure",        kind: .expense, icon: "ticket.fill")
            let other_exp  = try categories.insert(name: "Other (expense)", kind: .expense, icon: "ellipsis.circle")

            // Default income categories
            let salary     = try categories.insert(name: "Salary",         kind: .income, icon: "yensign.circle.fill")
            let bonus      = try categories.insert(name: "Bonus",          kind: .income, icon: "gift.fill")
            let other_inc  = try categories.insert(name: "Other (income)", kind: .income, icon: "ellipsis.circle")

            // Default accounts
            let cash      = try accounts.insert(name: "Cash",      kind: .cash,   currency: "JPY", initialBalanceMinor: 30000)
            let bank      = try accounts.insert(name: "Bank",      kind: .bank,   currency: "JPY", initialBalanceMinor: 500000)
            let credit    = try accounts.insert(name: "Credit Card", kind: .credit, currency: "JPY", initialBalanceMinor: 0)

            _ = (other_exp, other_inc, bonus) // suppress unused warnings if sample data is off

            guard addSampleTransactions else { return }

            // A few months of sample data so the dashboard shows something.
            let cal = Calendar.current
            let today = Date()
            var samples: [Transaction] = []
            let now = Date()

            for monthsAgo in 0..<3 {
                guard let monthStart = cal.date(byAdding: .month, value: -monthsAgo, to: today) else { continue }
                // Salary on the 25th
                if let pay = cal.date(bySetting: .day, value: 25, of: monthStart) {
                    samples.append(Transaction(
                        id: 0, occurredOn: pay, amountMinor: 320_000,
                        kind: .income, categoryId: salary, accountId: bank,
                        counterpartyAccountId: nil, note: "Monthly salary", tags: [],
                        createdAt: now, updatedAt: now
                    ))
                }
                // Rent on the 1st
                if let rentDay = cal.date(bySetting: .day, value: 1, of: monthStart) {
                    samples.append(Transaction(
                        id: 0, occurredOn: rentDay, amountMinor: 90_000,
                        kind: .expense, categoryId: rent, accountId: bank,
                        counterpartyAccountId: nil, note: "Rent", tags: ["fixed"],
                        createdAt: now, updatedAt: now
                    ))
                }
                // Utilities mid-month
                if let utilDay = cal.date(bySetting: .day, value: 15, of: monthStart) {
                    samples.append(Transaction(
                        id: 0, occurredOn: utilDay, amountMinor: 12_500,
                        kind: .expense, categoryId: utilities, accountId: bank,
                        counterpartyAccountId: nil, note: "Electric + gas", tags: ["fixed"],
                        createdAt: now, updatedAt: now
                    ))
                }
                // Sprinkle groceries / dining / transport / health / leisure
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
                        id: 0, occurredOn: d, amountMinor: weekly.0,
                        kind: .expense, categoryId: groceries, accountId: cash,
                        counterpartyAccountId: nil, note: "Weekly groceries", tags: [],
                        createdAt: now, updatedAt: now
                    ))
                    samples.append(Transaction(
                        id: 0, occurredOn: d, amountMinor: weekly.1,
                        kind: .expense, categoryId: dining, accountId: credit,
                        counterpartyAccountId: nil, note: "Restaurants", tags: [],
                        createdAt: now, updatedAt: now
                    ))
                    samples.append(Transaction(
                        id: 0, occurredOn: d, amountMinor: weekly.2,
                        kind: .expense, categoryId: transport, accountId: cash,
                        counterpartyAccountId: nil, note: "Train", tags: [],
                        createdAt: now, updatedAt: now
                    ))
                    if idx == 1 {
                        samples.append(Transaction(
                            id: 0, occurredOn: d, amountMinor: 2_400,
                            kind: .expense, categoryId: health, accountId: bank,
                            counterpartyAccountId: nil, note: "Pharmacy", tags: [],
                            createdAt: now, updatedAt: now
                        ))
                    }
                    if idx == 3 {
                        samples.append(Transaction(
                            id: 0, occurredOn: d, amountMinor: 4_500,
                            kind: .expense, categoryId: leisure, accountId: credit,
                            counterpartyAccountId: nil, note: "Movie + snacks", tags: [],
                            createdAt: now, updatedAt: now
                        ))
                    }
                }
            }

            try transactions.bulkInsert(samples)
        }
    }
}
