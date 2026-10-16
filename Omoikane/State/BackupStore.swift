import Foundation

/// Backups live next to the database in Application Support/Omoikane/Backups
/// as dated SQLite files. Automatic backups run at launch and on scene
/// activation when the configured interval has elapsed; the newest
/// `keepCount` files are kept.
enum BackupStore {
    struct BackupFile: Identifiable, Hashable {
        var url: URL
        var date: Date
        var bytes: Int64
        var id: URL { url }
    }

    enum Interval: Int, CaseIterable, Identifiable {
        case off = 0, daily = 1, weekly = 7
        var id: Int { rawValue }
        var displayName: String {
            switch self {
            case .off: return "Off"
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            }
        }
    }

    static let keepCount = 10
    static let intervalKey = "omoikane.backupIntervalDays"
    static let lastBackupKey = "omoikane.lastBackupAt"

    static var interval: Interval {
        get { Interval(rawValue: UserDefaults.standard.integer(forKey: intervalKey)) ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: intervalKey) }
    }
    static var lastBackup: Date? {
        get { UserDefaults.standard.object(forKey: lastBackupKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastBackupKey) }
    }

    static func directory(for db: Database) throws -> URL {
        let dir = db.url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func list(for db: Database) -> [BackupFile] {
        guard let dir = try? directory(for: db),
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return [] }
        return urls
            .filter { $0.pathExtension == "sqlite" }
            .compactMap { url in
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return BackupFile(url: url, date: v?.contentModificationDate ?? .distantPast, bytes: Int64(v?.fileSize ?? 0))
            }
            .sorted { $0.date > $1.date }
    }

    /// Write a new dated backup, prune to `keepCount`, record the time.
    @discardableResult
    static func backup(db: Database) throws -> URL {
        let dir = try directory(for: db)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // fixed pattern regardless of 12/24-hour locale
        f.dateFormat = "yyyy-MM-dd-HHmmss"             // local time, filename-safe
        let stamp = f.string(from: Date())
        var url = dir.appendingPathComponent("Omoikane-\(stamp).sqlite")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {   // two backups in one second
            url = dir.appendingPathComponent("Omoikane-\(stamp)-\(n).sqlite"); n += 1
        }
        try db.sync { try db.copy(to: url) }
        removeSidecars(of: url)
        for old in list(for: db).dropFirst(keepCount) {
            try? FileManager.default.removeItem(at: old.url)
            removeSidecars(of: old.url)
        }
        lastBackup = Date()
        return url
    }

    /// Back up if the interval is on and has elapsed since the last one.
    static func backupIfDue(db: Database) {
        let days = interval.rawValue
        guard days > 0 else { return }
        if let last = lastBackup, Date().timeIntervalSince(last) < TimeInterval(days) * 86_400 { return }
        _ = try? backup(db: db)
    }

    static func delete(_ file: BackupFile) throws {
        try FileManager.default.removeItem(at: file.url)
        removeSidecars(of: file.url)
    }

    /// WAL/shm files SQLite may leave next to a copy; the backup itself is
    /// switched to a rollback journal so they carry nothing.
    static func removeSidecars(of url: URL) {
        for suffix in ["-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}
