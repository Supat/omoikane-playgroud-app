import Foundation

/// Reads and writes `currency_rates`. The home currency itself is owned by
/// AppState (UserDefaults) — this table only stores the *other* currencies.
final class CurrencyStore {
    private let db: Database
    init(db: Database) { self.db = db }

    func list() throws -> [CurrencyRate] {
        let s = try db.prepare("""
            SELECT currency, rate_to_home, updated_at
              FROM currency_rates
             ORDER BY currency;
        """)
        var out: [CurrencyRate] = []
        while try s.step() {
            out.append(CurrencyRate(
                currency: s.string(0),
                rateToHome: s.double(1),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(s.int64(2)))
            ))
        }
        return out
    }

    func upsert(currency: String, rateToHome: Double) throws {
        let now = Int64(Date().timeIntervalSince1970)
        let s = try db.prepare("""
            INSERT INTO currency_rates (currency, rate_to_home, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(currency) DO UPDATE SET
                rate_to_home = excluded.rate_to_home,
                updated_at   = excluded.updated_at;
        """)
        s.bind(currency,   at: 1)
        s.bind(rateToHome, at: 2)
        s.bind(now,        at: 3)
        try s.step()
    }

    func delete(currency: String) throws {
        let s = try db.prepare("DELETE FROM currency_rates WHERE currency = ?;")
        s.bind(currency, at: 1)
        try s.step()
    }
}
