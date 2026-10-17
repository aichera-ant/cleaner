import CleanerKit
import Foundation

/// Mükerrer grubu: aynı içerikli kopyalar.
public struct DuplicateGroup: Sendable, Equatable, Identifiable {
    public var id: String
    public var members: [CleanItem]

    /// Her kopyanın boyutu (aynı içerik).
    public var perCopyBytes: UInt64 { members.map(\.allocatedBytes).max() ?? 0 }
    /// Grubun tamamı kilitli mi (hiçbir kopya taşınamaz)?
    public var untouchable: Bool { members.allSatisfy { $0.isLocked } }
}

public enum Summaries {
    /// Mükerrer öğeleri gruplara böler; gruplar tasarruf potansiyeline göre azalan sırada.
    public static func duplicateGroups(_ items: [CleanItem]) -> [DuplicateGroup] {
        var order: [String] = []
        var map: [String: [CleanItem]] = [:]
        for i in items where i.category == .duplicates {
            guard let g = i.groupID else { continue }
            if map[g] == nil { order.append(g) }
            map[g, default: []].append(i)
        }
        // Grup içinde önerilen tutulacak kopya önde, sonra yola göre.
        let groups = order.map { g in
            DuplicateGroup(id: g, members: map[g]!.sorted {
                ($0.isDuplicateKeeper ? 0 : 1, $0.path) < ($1.isDuplicateKeeper ? 0 : 1, $1.path)
            })
        }
        return groups.sorted { ($0.perCopyBytes * UInt64($0.members.count), $1.id) > ($1.perCopyBytes * UInt64($1.members.count), $0.id) }
    }

    /// Boyuta göre azalan, eşitlikte yola göre.
    public static func sorted(_ items: [CleanItem]) -> [CleanItem] {
        items.sorted { ($0.allocatedBytes, $1.path) > ($1.allocatedBytes, $0.path) }
    }

    public static func items(in category: CleanerKit.Category, _ items: [CleanItem]) -> [CleanItem] {
        sorted(items.filter { $0.category == category })
    }

    public static func totalBytes(_ items: [CleanItem]) -> UInt64 {
        items.reduce(0) { $0 &+ $1.allocatedBytes }
    }

    public static func totals(_ items: [CleanItem]) -> [CleanerKit.Category: UInt64] {
        var t: [CleanerKit.Category: UInt64] = [:]
        for i in items { t[i.category, default: 0] &+= i.allocatedBytes }
        return t
    }

    /// "Güvenle temizlenebilir": yeşil, kilitsiz, temizlenebilir öğeler (tutulacak kopya hariç).
    public static func cleanableBytes(_ items: [CleanItem], selection: SelectionState = SelectionState()) -> UInt64 {
        items.filter { $0.risk == .green && SelectionState.baseSelectable($0) && !selection.isKeeper($0) }
            .reduce(0) { $0 &+ $1.allocatedBytes }
    }

    public struct RiskCounts: Sendable, Equatable {
        public var green = 0, yellow = 0, red = 0, locked = 0
    }

    public static func riskCounts(_ items: [CleanItem]) -> RiskCounts {
        var c = RiskCounts()
        for i in items {
            if i.isLocked { c.locked += 1; continue }
            switch i.risk {
            case .green: c.green += 1
            case .yellow: c.yellow += 1
            case .red: c.red += 1
            case .locked: c.locked += 1
            case .info: break
            }
        }
        return c
    }
}

/// Taşımadan önceki onay sayfasının içeriği.
public struct TrashPlan: Sendable, Equatable {
    /// Çöp Kutusu'na gidecekler, kategoriye göre (kategori sırası sabit).
    public var trashGroups: [(category: CleanerKit.Category, items: [CleanItem])]
    /// Komutla temizlenecekler (Çöp Kutusu'na gitmez).
    public var commandItems: [CleanItem]
    /// Yeşil olmayan, kullanıcının seçtiği öğeler.
    public var nonGreen: [CleanItem]
    public var itemCount: Int
    public var totalBytes: UInt64
    public var ids: [String]

    public var trashCount: Int { trashGroups.reduce(0) { $0 + $1.items.count } }
    public var commandBytes: UInt64 { Summaries.totalBytes(commandItems) }

    public static func == (a: TrashPlan, b: TrashPlan) -> Bool {
        a.ids == b.ids && a.totalBytes == b.totalBytes && a.commandItems == b.commandItems && a.nonGreen == b.nonGreen
    }

    public init(selected: [CleanItem]) {
        let sortedItems = Summaries.sorted(selected)
        var groups: [(CleanerKit.Category, [CleanItem])] = []
        var cmds: [CleanItem] = []
        for cat in CleanerKit.Category.allCases {
            let inCat = sortedItems.filter { $0.category == cat && !Self.isCommand($0) }
            if !inCat.isEmpty { groups.append((cat, inCat)) }
        }
        for i in sortedItems where Self.isCommand(i) { cmds.append(i) }
        trashGroups = groups.map { (category: $0.0, items: $0.1) }
        commandItems = cmds
        nonGreen = sortedItems.filter { $0.risk != .green }
        itemCount = sortedItems.count
        totalBytes = Summaries.totalBytes(sortedItems)
        ids = sortedItems.map(\.id)
    }

    static func isCommand(_ i: CleanItem) -> Bool {
        if case .command = i.method { return true }
        return false
    }
}

/// Tarama sonucunun tazeliği: 15 dakikadan eskiyse taşımadan önce yeniden tarama istenir.
public enum ScanFreshness {
    public static let maxAge: TimeInterval = 15 * 60

    public static func isStale(scannedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(scannedAt) > maxAge
    }
}

/// Taşıma sonucu özeti.
public struct TrashOutcome: Sendable, Equatable {
    public struct Line: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var path: String
        public var reason: String
    }

    public var trashedCount: Int
    public var commandCount: Int
    public var trashedBytes: UInt64
    public var commandBytes: UInt64
    public var refused: [Line]
    public var skipped: [Line]

    public var freedBytes: UInt64 { trashedBytes &+ commandBytes }
    public var doneCount: Int { trashedCount + commandCount }

    public init(report: TrashReport, items: [CleanItem]) {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func line(_ r: TrashReport.Refused) -> Line {
            let item = byID[r.id]
            let path = r.path.isEmpty ? (item?.path ?? "") : r.path
            return Line(id: r.id, name: item?.name ?? (path as NSString).lastPathComponent, path: path, reason: r.reason)
        }
        let trashed = report.done.filter { $0.action == .trashed }
        let commands = report.done.filter { $0.action == .command }
        trashedCount = trashed.count
        commandCount = commands.count
        trashedBytes = trashed.reduce(0) { $0 &+ $1.bytes }
        commandBytes = commands.reduce(0) { $0 &+ $1.bytes }
        refused = report.refused.map(line)
        skipped = report.skipped.map(line)
    }
}

/// Tarama ekranının ilerleme durumu (kategori satırları + yüzde).
public struct ScanProgressState: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case pending, running
        case done(itemCount: Int, bytes: UInt64)
        case failed(String)
    }

    public private(set) var rows: [CleanerKit.Category: Status] = [:]
    public private(set) var completed = 0
    public private(set) var total = 0

    public init() {
        for c in CleanerKit.Category.allCases { rows[c] = .pending }
    }

    public var fraction: Double { total == 0 ? 0 : min(1, Double(completed) / Double(total)) }

    public func status(_ c: CleanerKit.Category) -> Status { rows[c] ?? .pending }

    public mutating func apply(_ p: AppScanProgress) {
        total = p.total
        completed = max(completed, p.completed)
        // Bir tarayıcı birden çok kategori üretebilir: bitiş toplamı kategorilere dağıtılamaz; ilk kategoriye yazılır,
        // diğerleri bitti (0) görünür. Ayrıntılı dağılım sonuç geldiğinde `finish(items:)` ile düzelir.
        switch p.event {
        case .started:
            for c in p.categories where status(c) == .pending { rows[c] = .running }
        case .finished(let n, let b):
            for (idx, c) in p.categories.enumerated() { rows[c] = .done(itemCount: idx == 0 ? n : 0, bytes: idx == 0 ? b : 0) }
        case .failed(let msg):
            for c in p.categories { rows[c] = .failed(msg) }
        }
    }

    /// Sonuç gelince satırları gerçek kategori toplamlarıyla doldurur.
    public mutating func finish(items: [CleanItem]) {
        completed = total
        for c in CleanerKit.Category.allCases {
            let mine = items.filter { $0.category == c }
            if case .failed = status(c) { continue }
            rows[c] = .done(itemCount: mine.count, bytes: Summaries.totalBytes(mine))
        }
    }
}

public struct DiskInfo: Sendable, Equatable {
    public var totalBytes: UInt64
    public var availableBytes: UInt64
    public var usedBytes: UInt64 { totalBytes > availableBytes ? totalBytes - availableBytes : 0 }

    public init(totalBytes: UInt64, availableBytes: UInt64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    /// Ana birim: boş alan `volumeAvailableCapacityForImportantUsage`.
    public static func current() -> DiskInfo? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let avail = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity else { return nil }
        return DiskInfo(totalBytes: UInt64(max(0, total)), availableBytes: UInt64(max(0, avail)))
    }
}
