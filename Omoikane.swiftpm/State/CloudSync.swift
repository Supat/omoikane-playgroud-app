import Foundation
import CloudKit
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// The CloudKit half of iCloud sync: a private custom zone holding one
/// record per synced row (record type = table, record name = uuid, fields =
/// columns, foreign keys as uuids, a `nulls` list naming the columns that
/// are NULL). `SyncStore` owns everything SQLite; this class moves records
/// and keeps the zone change token.
///
/// Pull before push, always: a delete that arrives first removes the local
/// row and its outbox entry, so a stale edit never goes up. Conflicts on
/// push compare `updated_at` with the server copy; the newer one stays.
///
/// Needs the iCloud (CloudKit) capability, so only the Xcode build can turn
/// it on; the toggle defaults to off.
@Observable
final class CloudSync {
    static let containerID = "iCloud.com.supatsaetia.omoikane"
    static let zoneName = "Ledger"
    static let enabledKey = "omoikane.icloudSync"
    /// Set by the app delegate so a silent push can trigger a pull.
    static weak var active: CloudSync?

    private let db: Database
    private let store: SyncStore
    /// Runs after remote rows landed: the owner refreshes rates and bumps the data version.
    var onApplied: () -> Void = {}

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { scheduleSync(after: 0) } else { status = "Off" }
        }
    }
    private(set) var status = "Off"
    private(set) var lastSync: Date?
    private(set) var isSyncing = false
    private var scheduled: Task<Void, Never>?
    private var registeredForPush = false

    /// Built on demand: constructing it in a build without the entitlement must not happen at launch.
    private var container: CKContainer { CKContainer(identifier: Self.containerID) }
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: CloudSync.zoneName, ownerName: CKCurrentUserDefaultName)

    init(db: Database, store: SyncStore) {
        self.db = db
        self.store = store
        self.enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        Self.active = self
    }

    func pendingCount() -> Int { (try? db.sync { try store.pendingCount() }) ?? 0 }

    /// Debounced: edits in quick succession become one push.
    func scheduleSync(after seconds: Double = 3) {
        guard enabled else { return }
        scheduled?.cancel()
        scheduled = Task { @MainActor in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled else { return }
            await syncNow()
        }
    }

    @MainActor
    func syncNow() async {
        guard enabled, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            guard try await container.accountStatus() == .available else {
                status = "Sign in to iCloud to sync."
                return
            }
            #if canImport(UIKit)
            if !registeredForPush { UIApplication.shared.registerForRemoteNotifications(); registeredForPush = true }
            #endif
            try await ensureZone()
            try await ensureSubscription()
            let applied = try await pull()
            if applied > 0 { onApplied() }
            try await push()
            try db.sync { try store.sweepTombstones() }
            lastSync = Date()
            status = "Up to date"
        } catch let e as CKError where [.changeTokenExpired, .zoneNotFound, .userDeletedZone].contains(e.code) {
            // Start over from an empty token; last-writer-wins sorts out the rest.
            try? db.sync { try store.resetRemoteState() }
            status = "iCloud zone reset. Sync again."
        } catch {
            status = "Sync failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Zone and subscription

    private func ensureZone() async throws {
        if try db.sync({ try store.state("zone") }) != nil { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        try db.sync { try store.setState("zone", Data([1])) }
    }

    private func ensureSubscription() async throws {
        if try db.sync({ try store.state("subscription") }) != nil { return }
        let sub = CKDatabaseSubscription(subscriptionID: "ledger-changes")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        _ = try await database.modifySubscriptions(saving: [sub], deleting: [])
        try db.sync { try store.setState("subscription", Data([1])) }
    }

    // MARK: - Pull

    private func pull() async throws -> Int {
        var token = try changeToken()
        var applied = 0
        var more = true
        while more {
            let r = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            let records = r.modificationResultsByID.values.compactMap { try? $0.get().record }
            let deletes = r.deletions.map { (table: $0.recordType, uuid: $0.recordID.recordName) }
            applied += try db.sync {
                let ups = try records.compactMap { try decode($0) }
                return try store.apply(upserts: ups, deletes: deletes)
            }
            token = r.changeToken
            let data = try NSKeyedArchiver.archivedData(withRootObject: r.changeToken, requiringSecureCoding: true)
            try db.sync { try store.setState("token", data) }
            more = r.moreComing
        }
        return applied
    }

    private func changeToken() throws -> CKServerChangeToken? {
        guard let d = try db.sync({ try store.state("token") }) else { return nil }
        return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: d)
    }

    // MARK: - Push

    private func push() async throws {
        let pending = try db.sync { try store.pendingUpserts() }
        let tombstones = try db.sync { try store.pendingDeletes() }
        guard !pending.records.isEmpty || !tombstones.deletes.isEmpty else { return }
        var saves = pending.records.map(encode)
        var deleteIDs = tombstones.deletes.map { CKRecord.ID(recordName: $0.uuid, zoneID: zoneID) }
        while !saves.isEmpty || !deleteIDs.isEmpty {
            let s = Array(saves.prefix(400)); saves.removeFirst(s.count)
            let d = Array(deleteIDs.prefix(400 - s.count)); deleteIDs.removeFirst(d.count)
            let r = try await database.modifyRecords(saving: s, deleting: d, savePolicy: .ifServerRecordUnchanged, atomically: false)
            var retry: [CKRecord] = []
            for (id, result) in r.saveResults {
                guard case .failure(let e) = result else { continue }
                guard let ck = e as? CKError, ck.code == .serverRecordChanged else { throw e }
                // The server copy moved under us: keep whichever is newer.
                if let server = ck.serverRecord, let mine = s.first(where: { $0.recordID == id }),
                   Self.updatedAt(mine) > Self.updatedAt(server) {
                    Self.copy(mine, onto: server)
                    retry.append(server)
                }
            }
            for (_, result) in r.deleteResults {
                if case .failure(let e) = result, (e as? CKError)?.code != CKError.Code.unknownItem { throw e }
            }
            if !retry.isEmpty {
                let rr = try await database.modifyRecords(saving: retry, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
                for (_, result) in rr.saveResults {
                    // A second conflict means the other device is still writing; the next pull settles it.
                    if case .failure(let e) = result, (e as? CKError)?.code != CKError.Code.serverRecordChanged { throw e }
                }
            }
        }
        try db.sync { try store.markPushed(upsertSeq: pending.seq, deleteSeq: tombstones.seq) }
    }

    // MARK: - Record coding

    private func encode(_ r: SyncRecord) -> CKRecord {
        let rec = CKRecord(recordType: r.table, recordID: CKRecord.ID(recordName: r.uuid, zoneID: zoneID))
        var nulls: [String] = []
        for (k, v) in r.fields {
            switch v {
            case .int(let x):  rec.setObject(NSNumber(value: x), forKey: k)
            case .real(let x): rec.setObject(NSNumber(value: x), forKey: k)
            case .text(let x): rec.setObject(x as NSString, forKey: k)
            case .null:        nulls.append(k)
            }
        }
        rec.setObject(nulls.isEmpty ? nil : nulls as NSArray, forKey: "nulls")
        return rec
    }

    /// Columns the record does not mention are left alone on apply, so a
    /// record written by an older app version cannot blank newer columns.
    private func decode(_ r: CKRecord) throws -> SyncRecord? {
        guard SyncStore.table(named: r.recordType) != nil else { return nil }
        let nulls = Set(r.object(forKey: "nulls") as? [String] ?? [])
        var fields: [String: SyncValue] = [:]
        for c in try store.columns(of: r.recordType) where c.name != "id" && c.name != "uuid" {
            if nulls.contains(c.name) { fields[c.name] = .null; continue }
            guard let v = r.object(forKey: c.name) else { continue }
            if c.type.hasPrefix("INT")      { fields[c.name] = (v as? NSNumber).map { .int($0.int64Value) } ?? .null }
            else if c.type == "REAL"        { fields[c.name] = (v as? NSNumber).map { .real($0.doubleValue) } ?? .null }
            else                            { fields[c.name] = (v as? String).map { .text($0) } ?? .null }
        }
        return SyncRecord(table: r.recordType, uuid: r.recordID.recordName, fields: fields)
    }

    private static func updatedAt(_ r: CKRecord) -> Int64 { (r.object(forKey: "updated_at") as? NSNumber)?.int64Value ?? 0 }

    private static func copy(_ mine: CKRecord, onto server: CKRecord) {
        for key in server.allKeys() where mine.object(forKey: key) == nil { server.setObject(nil, forKey: key) }
        for key in mine.allKeys() { server.setObject(mine.object(forKey: key), forKey: key) }
    }
}
