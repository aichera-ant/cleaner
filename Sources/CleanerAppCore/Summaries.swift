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

/// Uygulamalar sayfasında bir uygulama ve artıkları.
public struct AppGroup: Sendable, Equatable, Identifiable {
    public var app: CleanItem
    /// Boyuta göre azalan.
    public var leftovers: [CleanItem]
    public var id: String { app.id }
    public var leftoverBytes: UInt64 { Summaries.totalBytes(leftovers) }
    public var exactCount: Int { leftovers.filter { $0.leftoverMatch == .bundleID }.count }
}

/// Uygulamalar sayfasının satır düzeni: uygulamalar seçili sıralamada, artıklar kendi uygulamasının altında.
public struct AppsLayout: Sendable, Equatable {
    public var groups: [AppGroup]
    /// `parentAppID` dolu ama uygulama öğesi taramada olmayan artıklar.
    public var orphans: [CleanItem]
}

/// "Uygulamalar" özet kartı: uygulama sayısı ve boyutu ile artıkların toplamı.
public struct AppsSummary: Sendable, Equatable {
    public var appCount = 0
    public var appBytes: UInt64 = 0
    public var leftoverCount = 0
    public var leftoverBytes: UInt64 = 0
    public var totalBytes: UInt64 { appBytes &+ leftoverBytes }
}

public enum Summaries {
    public static func appsLayout(_ items: [CleanItem], sort: ItemSort) -> AppsLayout {
        let apps = items.filter { $0.category == .apps && !$0.isLeftover }
        let ids = Set(apps.map(\.id))
        var byParent: [String: [CleanItem]] = [:]
        var orphans: [CleanItem] = []
        for l in items where l.category == .apps && l.isLeftover {
            if let a = l.parentAppID, ids.contains(a) { byParent[a, default: []].append(l) } else { orphans.append(l) }
        }
        let groups = sort.sorted(apps).map { a in
            AppGroup(app: a, leftovers: sorted(byParent[a.id] ?? []))
        }
        return AppsLayout(groups: groups, orphans: sorted(orphans))
    }

    public static func appsSummary(_ items: [CleanItem]) -> AppsSummary {
        var s = AppsSummary()
        for i in items where i.category == .apps {
            if i.isLeftover { s.leftoverCount += 1; s.leftoverBytes &+= i.allocatedBytes } else { s.appCount += 1; s.appBytes &+= i.allocatedBytes }
        }
        return s
    }

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

    public static func items(in category: ItemCategory, _ items: [CleanItem]) -> [CleanItem] {
        sorted(items.filter { $0.category == category })
    }

    public static func totalBytes(_ items: [CleanItem]) -> UInt64 {
        items.reduce(0) { $0 &+ $1.allocatedBytes }
    }

    public static func totals(_ items: [CleanItem]) -> [ItemCategory: UInt64] {
        var t: [ItemCategory: UInt64] = [:]
        for i in items { t[i.category, default: 0] &+= i.allocatedBytes }
        return t
    }

    /// "Güvenle temizlenebilir": yeşil, kilitsiz, temizlenebilir öğeler (tutulacak kopya hariç).
    public static func cleanableBytes(_ items: [CleanItem], selection: SelectionState = SelectionState()) -> UInt64 {
        items.filter { selection.effective($0).isDefaultSelected && selection.isSelectable($0) }
            .reduce(0) { $0 &+ $1.allocatedBytes }
    }

    /// Yeşil ve seçilebilir ama varsayılan seçimde olmayan öğeler (ör. son 30 günde kullanılan proje artıkları).
    /// Özet kartı bunları "güvenle temizlenebilir" sayısından ayrı gösterir.
    public static func heldBackGreens(_ items: [CleanItem], selection: SelectionState = SelectionState()) -> [CleanItem] {
        items.filter {
            let e = selection.effective($0)
            return !$0.isLeftover && e.risk == .green && !e.isLocked && e.method != .none && selection.isSelectable($0) && !e.isDefaultSelected
        }
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

/// Onay sayfasında bir uygulama ve altında seçili artıkları. `app == nil`: uygulaması seçili olmayan artıklar.
public struct PlanAppGroup: Sendable, Equatable, Identifiable {
    public var app: CleanItem?
    public var leftovers: [CleanItem]
    public var id: String { app?.id ?? "leftovers-only" }
    public var bytes: UInt64 { Summaries.totalBytes(leftovers) &+ (app?.allocatedBytes ?? 0) }
}

/// Taşımadan önceki onay sayfasının içeriği.
public struct TrashPlan: Sendable, Equatable {
    /// Çöp Kutusu'na gidecekler, kategoriye göre (kategori sırası sabit).
    public var trashGroups: [(category: ItemCategory, items: [CleanItem])]
    /// Komutla temizlenecekler (Çöp Kutusu'na gitmez).
    public var commandItems: [CleanItem]
    /// Yeşil olmayan, kullanıcının seçtiği öğeler.
    public var nonGreen: [CleanItem]
    /// Taşırken macOS parola ya da Touch ID isteyecek olanlar (seçilenlerin alt kümesi).
    public var authorizationItems: [CleanItem]
    /// `trashGroups` içindeki uygulamalar kategorisi: uygulama ve altında artıkları. Uygulaması seçilmeyen artıklar
    /// sonda tek grupta (`app == nil`).
    public var appGroups: [PlanAppGroup]
    public var itemCount: Int
    public var totalBytes: UInt64
    public var ids: [String]
    /// "Bunu tut" seçimleri (grup kimliği -> yol). Önizlemeden sonra değişirse plan farklı sayılır.
    public var keepers: [String: String]

    public var trashCount: Int { trashGroups.reduce(0) { $0 + $1.items.count } }
    public var commandBytes: UInt64 { Summaries.totalBytes(commandItems) }

    public static func == (a: TrashPlan, b: TrashPlan) -> Bool {
        a.ids == b.ids && a.totalBytes == b.totalBytes && a.commandItems == b.commandItems && a.nonGreen == b.nonGreen
            && a.authorizationItems == b.authorizationItems && a.keepers == b.keepers
    }

    /// Kalıcı silme uyarısında adı geçen en çok öğe sayısı.
    static let warningNameLimit = 3

    /// Komutla (kalıcı) temizlenecek öğe varsa uyarı metni: "N öğe kalıcı silinir, geri alınamaz: a, b ve X daha".
    public var permanentDeleteWarning: String? {
        guard !commandItems.isEmpty else { return nil }
        let names = commandItems.prefix(Self.warningNameLimit).map(\.name).joined(separator: ", ")
        let more = commandItems.count - Self.warningNameLimit
        let tail = more > 0 ? " ve \(more) daha" : ""
        return "\(commandItems.count) öğe kalıcı silinir, geri alınamaz: \(names)\(tail)."
    }

    /// Onay düğmesi: komutlu öğe varsa hepsi Çöp Kutusu'na gitmez.
    public var confirmButtonTitle: String { commandItems.isEmpty ? "Çöp Kutusu'na taşı" : "Taşı ve temizle" }

    public init(selected: [CleanItem], keepers: [String: String] = [:]) {
        self.keepers = keepers
        let sortedItems = Summaries.sorted(selected)
        var groups: [(ItemCategory, [CleanItem])] = []
        var cmds: [CleanItem] = []
        for cat in ItemCategory.allCases {
            let inCat = sortedItems.filter { $0.category == cat && !Self.isCommand($0) }
            if !inCat.isEmpty { groups.append((cat, inCat)) }
        }
        for i in sortedItems where Self.isCommand(i) { cmds.append(i) }
        trashGroups = groups.map { (category: $0.0, items: $0.1) }
        appGroups = Self.planAppGroups(groups.first { $0.0 == .apps }?.1 ?? [])
        commandItems = cmds
        nonGreen = sortedItems.filter { $0.risk != .green }
        authorizationItems = sortedItems.filter { Fmt.needsAuthorization($0) }
        itemCount = sortedItems.count
        totalBytes = Summaries.totalBytes(sortedItems)
        ids = sortedItems.map(\.id)
    }

    static func planAppGroups(_ items: [CleanItem]) -> [PlanAppGroup] {
        let apps = items.filter { !$0.isLeftover }
        let ids = Set(apps.map(\.id))
        let leftovers = items.filter(\.isLeftover)
        var out = apps.map { a in
            PlanAppGroup(app: a, leftovers: leftovers.filter { $0.parentAppID == a.id })
        }
        let rest = leftovers.filter { $0.parentAppID.map { !ids.contains($0) } ?? true }
        if !rest.isEmpty { out.append(PlanAppGroup(app: nil, leftovers: rest)) }
        return out
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
        /// Artıksa bağlı olduğu uygulama öğesinin id'si ve adı (tarama sonucunda varsa).
        public var parentAppID: String?
        public var parentName: String?
    }

    /// Çekirdeğin, uygulaması taşınamayan artığa yazdığı neden.
    public static let appFailedSkipReason = "uygulama taşınamadığı için atlandı"

    /// Uygulaması taşınamadığı için atlanan artıklar, uygulamasına göre.
    public struct AppSkipGroup: Sendable, Equatable, Identifiable {
        public var appID: String
        public var appName: String
        public var lines: [Line]
        public var id: String { appID }
    }

    public var trashedCount: Int
    public var commandCount: Int
    public var trashedBytes: UInt64
    public var commandBytes: UInt64
    public var refused: [Line]
    public var skipped: [Line]

    /// Reddedilenlerden, "uygulama taşınamadığı için atlandı" nedenli artıklar hariç olanlar.
    public var refusedOther: [Line] { refused.filter { !Self.isAppSkip($0) } }

    /// "Uygulama taşınamadığı için atlandı" nedenli artıklar, uygulamasının altında (uygulama sırası ilk görülme sırası).
    public var appSkipGroups: [AppSkipGroup] {
        var order: [String] = []
        var map: [String: AppSkipGroup] = [:]
        for l in refused where Self.isAppSkip(l) {
            let key = l.parentAppID ?? "unknown"
            if map[key] == nil {
                order.append(key)
                map[key] = AppSkipGroup(appID: key, appName: l.parentName ?? "Bilinmeyen uygulama", lines: [])
            }
            map[key]?.lines.append(l)
        }
        return order.compactMap { map[$0] }
    }

    private static func isAppSkip(_ l: Line) -> Bool { l.reason.contains(appFailedSkipReason) }

    /// Taşınamayan öğe sayısı (bütün retler, uygulaması taşınamadığı için atlanan artıklar dahil; atlananlar hariç).
    public var failedCount: Int { refused.count }

    /// En az bir ret Tam Disk Erişimi eksikliğinden mi (macOS uygulama verisi koruması)?
    public var needsFullDiskAccess: Bool { refused.contains { $0.reason.contains(Trasher.fullDiskAccessMarker) } }

    /// Sonuç başlığı: ret varsa açıkça "N öğe taşınamadı".
    public var headline: String {
        if failedCount == 0 { return "Temizlik tamamlandı" }
        if doneCount == 0 { return failedCount == 1 ? "Öğe taşınamadı" : "\(failedCount) öğenin hiçbiri taşınamadı" }
        return "\(failedCount) öğe taşınamadı"
    }

    public var freedBytes: UInt64 { trashedBytes &+ commandBytes }
    public var doneCount: Int { trashedCount + commandCount }

    public init(report: TrashReport, items: [CleanItem]) {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func line(_ r: TrashReport.Refused) -> Line {
            let item = byID[r.id]
            let path = r.path.isEmpty ? (item?.path ?? "") : r.path
            let parent = item?.parentAppID.flatMap { byID[$0] }
            return Line(id: r.id, name: item?.name ?? (path as NSString).lastPathComponent, path: path, reason: r.reason,
                        parentAppID: item?.parentAppID, parentName: parent?.name)
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

    public private(set) var rows: [ItemCategory: Status] = [:]
    public private(set) var completed = 0
    public private(set) var total = 0

    public init() {
        for c in ItemCategory.allCases { rows[c] = .pending }
    }

    public var fraction: Double { total == 0 ? 0 : min(1, Double(completed) / Double(total)) }

    public func status(_ c: ItemCategory) -> Status { rows[c] ?? .pending }

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
        for c in ItemCategory.allCases {
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
