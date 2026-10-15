import Foundation

final class ScheduleStore {
    private let db: Database
    private let transactions: TransactionStore
    init(db: Database, transactions: TransactionStore) {
        self.db = db
        self.transactions = transactions
    }

    private static let columns = """
        SELECT id, kind, amount_minor, category_id, account_id, counterparty_account_id,
               counterparty_amount_minor, payee_id, note, frequency, interval, next_due, end_on
    """

    func list() throws -> [Schedule] {
        let s = try db.prepare(Self.columns + " FROM schedules ORDER BY next_due, id;")
        var out: [Schedule] = []
        while try s.step() { out.append(Self.read(s)) }
        return out
    }

    @discardableResult
    func insert(_ sc: Schedule) throws -> Int64 {
        let s = try db.prepare("""
            INSERT INTO schedules (kind, amount_minor, category_id, account_id, counterparty_account_id,
                                   counterparty_amount_minor, payee_id, note, frequency, interval, next_due, end_on)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
        """)
        bind(s, sc)
        try s.step()
        return db.lastInsertId
    }

    func update(_ sc: Schedule) throws {
        let s = try db.prepare("""
            UPDATE schedules
               SET kind = ?, amount_minor = ?, category_id = ?, account_id = ?, counterparty_account_id = ?,
                   counterparty_amount_minor = ?, payee_id = ?, note = ?, frequency = ?, interval = ?,
                   next_due = ?, end_on = ?
             WHERE id = ?;
        """)
        bind(s, sc)
        s.bind(sc.id, at: 13)
        try s.step()
    }

    func delete(id: Int64) throws {
        let s = try db.prepare("DELETE FROM schedules WHERE id = ?;")
        s.bind(id, at: 1)
        try s.step()
    }

    /// Insert a real transaction for every occurrence due on or before
    /// `today`, advancing `next_due` each time. Schedules that run past
    /// `end_on` are deleted. Returns how many rows were posted.
    /// ponytail: one occurrence per step, so a schedule missed for a year
    /// posts twelve rows on the next launch — that is what Money Pro does too.
    @discardableResult
    func postDue(today: Date = Date()) throws -> Int {
        var posted = 0
        try db.transaction {
            let accounts = AccountStore(db: db)
            let todayKey = today.dayKey
            for var sc in try list() {
                var guardCount = 0
                while sc.nextDue.dayKey <= todayKey, guardCount < 1000 {
                    guardCount += 1
                    if let end = sc.endOn, sc.nextDue.dayKey > end.dayKey { break }
                    let acct = try accounts.get(id: sc.accountId)
                    let now = Date()
                    var tx = Transaction(
                        id: 0,
                        occurredOn: sc.nextDue,
                        amountMinor: sc.amountMinor,
                        currency: acct?.currency ?? "JPY",
                        kind: sc.kind,
                        categoryId: sc.categoryId,
                        accountId: sc.accountId,
                        counterpartyAccountId: sc.kind == .transfer ? sc.counterpartyAccountId : nil,
                        counterpartyAmountMinor: sc.kind == .transfer ? sc.counterpartyAmountMinor : nil,
                        note: sc.note,
                        tags: [],
                        createdAt: now,
                        updatedAt: now
                    )
                    tx.payeeId = sc.payeeId
                    if acct?.clearsEntriesByDefault == true { tx.clearedAt = now }
                    _ = try transactions.insert(tx)
                    posted += 1
                    sc.nextDue = Self.advance(sc.nextDue, by: sc)
                }
                if let end = sc.endOn, sc.nextDue.dayKey > end.dayKey {
                    try delete(id: sc.id)
                } else {
                    try update(sc)
                }
            }
        }
        return posted
    }

    static func advance(_ date: Date, by sc: Schedule) -> Date {
        Calendar.current.date(byAdding: sc.frequency.calendarComponent, value: max(1, sc.interval), to: date) ?? date
    }

    private func bind(_ s: Statement, _ sc: Schedule) {
        s.bind(sc.kind.rawValue, at: 1)
        s.bind(sc.amountMinor, at: 2)
        s.bind(sc.categoryId, at: 3)
        s.bind(sc.accountId, at: 4)
        s.bind(sc.counterpartyAccountId, at: 5)
        s.bind(sc.counterpartyAmountMinor, at: 6)
        s.bind(sc.payeeId, at: 7)
        s.bind(sc.note, at: 8)
        s.bind(sc.frequency.rawValue, at: 9)
        s.bind(sc.interval, at: 10)
        s.bind(Int64(sc.nextDue.dayKey), at: 11)
        s.bind(sc.endOn.map { Int64($0.dayKey) }, at: 12)
    }

    private static func read(_ s: Statement) -> Schedule {
        Schedule(
            id: s.int64(0),
            kind: TransactionKind(rawValue: s.string(1)) ?? .expense,
            amountMinor: s.int64(2),
            categoryId: s.int64(3),
            accountId: s.int64(4),
            counterpartyAccountId: s.optionalInt64(5),
            counterpartyAmountMinor: s.optionalInt64(6),
            payeeId: s.optionalInt64(7),
            note: s.optionalString(8),
            frequency: ScheduleFrequency(rawValue: s.string(9)) ?? .monthly,
            interval: s.int(10),
            nextDue: Date.from(dayKey: s.int(11)),
            endOn: s.optionalInt64(12).map { Date.from(dayKey: Int($0)) }
        )
    }
}
