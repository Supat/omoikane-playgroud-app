import Foundation
import CloudKit
import Observation

/// The Watch's whole state: the last snapshot it saw (cached on disk so it
/// can capture offline) and the entries not yet uploaded. CloudKit is the
/// only link to the ledger, through the same private zone the iOS app
/// syncs; the zone is created by the iOS app, never here.
@Observable
final class WatchStore {
    private(set) var snapshot: WatchSnapshot?
    private(set) var queue: [WatchInboxEntry] = []
    private(set) var status = ""
    var lastAccountId: String? {
        get { UserDefaults.standard.string(forKey: "lastAccount") }
        set { UserDefaults.standard.set(newValue, forKey: "lastAccount") }
    }

    /// Built on first use, not at launch: CloudKit aborts a process without
    /// the iCloud entitlement the moment a container is created.
    private var database: CKDatabase { CKContainer(identifier: "iCloud.com.supatsaetia.omoikane.app").privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: "Ledger", ownerName: CKCurrentUserDefaultName)
    private var busy = false

    init() {
        snapshot = Self.load(WatchSnapshot.self, "snapshot.json")
        queue = Self.load([WatchInboxEntry].self, "queue.json") ?? []
    }

    // MARK: - Capture

    func add(_ entry: WatchInboxEntry) {
        queue.append(entry)
        Self.save(queue, "queue.json")
        lastAccountId = entry.accountId
        Task { await flush() }
    }

    // MARK: - CloudKit

    @MainActor
    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await flush()
        do {
            let id = CKRecord.ID(recordName: WatchSnapshot.recordName, zoneID: zoneID)
            let rec = try await database.record(for: id)
            if let data = rec.object(forKey: WatchSnapshot.payloadKey) as? Data {
                snapshot = try JSONDecoder().decode(WatchSnapshot.self, from: data)
                Self.save(snapshot, "snapshot.json")
                status = ""
            }
        } catch let e as CKError where e.code == .unknownItem || e.code == .zoneNotFound {
            status = "Turn on iCloud sync in Omoikane on your iPad or iPhone first."
        } catch {
            status = snapshot == nil ? error.localizedDescription : ""
        }
    }

    /// Upload everything queued; entries stay queued until CloudKit confirms.
    @MainActor
    func flush() async {
        guard !queue.isEmpty else { return }
        let records = queue.map { entry -> CKRecord in
            let r = CKRecord(recordType: WatchInboxEntry.recordType, recordID: CKRecord.ID(recordName: entry.id, zoneID: zoneID))
            r.setObject((try? JSONEncoder.sorted.encode(entry)) as NSData?, forKey: WatchInboxEntry.payloadKey)
            return r
        }
        do {
            let result = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
            let sent = Set(result.saveResults.compactMap { id, r in (try? r.get()) != nil ? id.recordName : nil })
            queue.removeAll { sent.contains($0.id) }
            Self.save(queue, "queue.json")
        } catch {
            status = "Will upload when iCloud is reachable."
        }
    }

    // MARK: - Disk cache

    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    private static func save<T: Encodable>(_ value: T?, _ name: String) {
        guard let value, let d = try? JSONEncoder.sorted.encode(value) else { return }
        try? d.write(to: dir.appendingPathComponent(name), options: .atomic)
    }
}
