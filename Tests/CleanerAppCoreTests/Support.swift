import CleanerKit
import Foundation
@testable import CleanerAppCore

func item(_ name: String, cat: ItemCategory = .caches, bytes: UInt64 = 100, risk: Risk = .green,
          lock: String? = nil, method: CleanMethod = .trash, preselect: Bool? = nil,
          group: String? = nil, keeper: String? = nil, auth: Bool? = nil,
          ifNotKeptRisk: Risk? = nil, ifNotKeptLock: String? = nil) -> CleanItem {
    var i = CleanItem(category: cat, name: name, path: "/tmp/cleaner-test/\(name)", allocatedBytes: bytes, risk: risk,
              lockReason: lock, method: method, preselect: preselect, groupID: group,
              keeperPath: keeper.map { "/tmp/cleaner-test/\($0)" }, needsAuthorization: auth)
    i.ifNotKeptRisk = ifNotKeptRisk
    i.ifNotKeptLockReason = ifNotKeptLock
    return i
}

final class FakeScan: ScanService, @unchecked Sendable {
    var snapshot: ScanSnapshot
    var events: [AppScanProgress] = []
    var error: (any Error)?
    init(_ snapshot: ScanSnapshot) { self.snapshot = snapshot }
    func scan(progress: (@Sendable (AppScanProgress) -> Void)?) async throws -> ScanSnapshot {
        for e in events { progress?(e) }
        if let error { throw error }
        return snapshot
    }
}

final class FakeTrash: TrashService, @unchecked Sendable {
    struct Call { var ids: [String]; var scan: [CleanItem]; var keepers: [String: String]; var dryRun: Bool }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    private func record(_ c: Call) { lock.lock(); _calls.append(c); lock.unlock() }
    func trash(ids: [String], scan: [CleanItem], keepers: [String: String], dryRun: Bool) async -> TrashReport {
        record(.init(ids: ids, scan: scan, keepers: keepers, dryRun: dryRun))
        let done = ids.compactMap { id in scan.first { $0.id == id } }.map {
            makeDone(id: $0.id, path: $0.path, bytes: $0.allocatedBytes, action: "trashed")
        }
        return TrashReport(dryRun: dryRun, done: done, refused: [])
    }
}

/// Saat sahtesi (Sendable kutu).
final class Clock: @unchecked Sendable {
    var date: Date
    init(_ d: Date) { date = d }
}

/// `TrashReport.Done` genel başlatıcı sunmaz; JSON'dan kurulur.
func makeDone(id: String, path: String, bytes: UInt64, action: String, detail: String? = nil) -> TrashReport.Done {
    var obj: [String: Any] = ["id": id, "path": path, "bytes": bytes, "action": action]
    if let detail { obj["detail"] = detail }
    let data = try! JSONSerialization.data(withJSONObject: obj)
    return try! JSONDecoder().decode(TrashReport.Done.self, from: data)
}

/// Uygulama öğesi (kategori apps).
func appItem(_ name: String, risk: Risk = .yellow, lock: String? = nil, auth: Bool? = nil, bytes: UInt64 = 1000,
             leftoverBytes: UInt64? = nil) -> CleanItem {
    CleanItem(category: .apps, name: name, path: "/tmp/cleaner-test/Applications/\(name).app", allocatedBytes: bytes, risk: risk,
              lockReason: lock, preselect: auth == true ? false : nil, needsAuthorization: auth, leftoverBytes: leftoverBytes)
}

/// Uygulama artığı; `parent` verilen uygulama öğesine bağlanır.
func leftoverItem(_ name: String, of parent: CleanItem?, match: LeftoverMatch = .bundleID, bytes: UInt64 = 100,
                  lock: String? = nil, path: String? = nil, parentID: String? = nil) -> CleanItem {
    CleanItem(category: .apps, name: name, path: path ?? "/tmp/cleaner-test/Library/Application Support/\(name)", allocatedBytes: bytes,
              risk: match == .bundleID ? .green : .yellow, lockReason: lock, preselect: false,
              parentAppID: parent?.id ?? parentID, leftoverMatch: match, appBundleID: "com.test.app",
              matchedName: match == .name ? "x" : nil)
}
