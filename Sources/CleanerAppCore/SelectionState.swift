import CleanerKit
import Foundation

/// Seçim durumu. Kurallar:
/// - Kilitli, `.info`, temizlenemez (`method == .none`) ve tutulacak kopya seçilemez.
/// - Varsayılan seçim `isDefaultSelected` (kırmızı/kilitli asla).
/// - "Bunu tut": grup için tutulacak yol durumda tutulur; o kopya seçilemez, seçiliyse seçimden çıkar.
///   Taramanın önerdiği özgün tutulacak kopya taşınabilir olur (`effective(_:)`, çekirdekteki `Trasher.applyKeepers` ile
///   aynı kural): riski `ifNotKeptRisk` (yoksa sarı), kilidi `ifNotKeptLockReason`; varsayılan seçimde değildir.
/// - Bir grubun bütün kopyaları seçilemez: en az biri kalır.
/// - Uygulama artıkları (`parentAppID`): uygulama seçimi yalnız kendi seçilen artıklarını getirir (`selectApp`);
///   uygulamanın seçimi kalkınca bağlı artıkların seçimi de kalkar; artık tek başına seçilebilir. Uygulaması taramada
///   olmayan (sahipsiz) artık seçilemez (çekirdek taşımayı reddeder). Toplu seçim ad benzerliği artıklarını seçmez.
public struct SelectionState: Sendable, Equatable {
    public private(set) var selectedIDs: Set<String> = []
    /// Mükerrer grup kimliği -> kullanıcının tutmak istediği yol.
    /// `Trasher.trash(ids:scan:dryRun:keepers:)`'a olduğu gibi geçer.
    public private(set) var keepers: [String: String] = [:]
    /// Mükerrer grup kimliği -> taramadaki (özgün) üyeler. "Hiç kopya kalmasın" engeli için.
    private var groupMembers: [String: [CleanItem]] = [:]
    /// Uygulama öğesinin id'si -> artıkları (boyuta göre azalan). Sahipsiz artık hiçbir listede yoktur.
    private var leftoversByApp: [String: [CleanItem]] = [:]
    private var appIDs: Set<String> = []

    public init() {}

    /// Varsayılan seçimle başlar.
    public init(defaultsFrom items: [CleanItem]) {
        register(items)
        for i in items where i.isDefaultSelected && Self.baseSelectable(i) { trySelect(i) }
    }

    /// Grup üyelerini tanır (yeni tarama sonucu).
    public mutating func register(_ items: [CleanItem]) {
        groupMembers = [:]
        leftoversByApp = [:]
        appIDs = []
        for i in items where i.category == .duplicates {
            if let g = i.groupID { groupMembers[g, default: []].append(i) }
        }
        for i in items where i.category == .apps && !i.isLeftover { appIDs.insert(i.id) }
        for i in items where i.category == .apps && i.isLeftover {
            if let a = i.parentAppID, appIDs.contains(a) { leftoversByApp[a, default: []].append(i) }
        }
        for (a, list) in leftoversByApp {
            leftoversByApp[a] = list.sorted { ($0.allocatedBytes, $1.path) > ($1.allocatedBytes, $0.path) }
        }
    }

    // MARK: Uygulama artıkları

    /// Uygulamanın artıkları (boyuta göre azalan).
    public func leftovers(of app: CleanItem) -> [CleanItem] { leftoversByApp[app.id] ?? [] }

    /// Uygulamanın şu an seçilebilir artıkları.
    public func selectableLeftovers(of app: CleanItem) -> [CleanItem] { leftovers(of: app).filter(isSelectable) }

    /// "Uygulama ve artıkları" sayfasında başta işaretli olanlar: seçilebilir kesin (`.bundleID`) artıklar.
    public func defaultLeftoverIDs(of app: CleanItem) -> Set<String> {
        Set(selectableLeftovers(of: app).filter { $0.leftoverMatch == .bundleID }.map(\.id))
    }

    /// Uygulamasının taramada olmadığı artık mı?
    public func isOrphan(_ item: CleanItem) -> Bool {
        guard item.isLeftover else { return false }
        guard let a = item.parentAppID else { return true }
        return !appIDs.contains(a)
    }

    /// Uygulamayı ve yalnız `leftoverIDs` içindeki (seçilebilir) artıklarını seçer; uygulamanın diğer artıklarının seçimini kaldırır.
    /// Uygulama seçilemezse (kilitli, bilgi) hiçbir şey yapmaz ve false döner.
    @discardableResult
    public mutating func selectApp(_ app: CleanItem, leftoverIDs: Set<String>) -> Bool {
        guard app.category == .apps, !app.isLeftover, isSelectable(app) else { return false }
        selectedIDs.insert(app.id)
        for l in leftovers(of: app) {
            if leftoverIDs.contains(l.id), isSelectable(l) { selectedIDs.insert(l.id) } else { selectedIDs.remove(l.id) }
        }
        return true
    }

    private mutating func deselectLeftovers(ofApp id: String) {
        for l in leftoversByApp[id] ?? [] { selectedIDs.remove(l.id) }
    }

    /// Kullanıcının "Bunu tut" seçimi uygulanmış öğe (çekirdekteki `applyKeepers` ile aynı alan değişiklikleri;
    /// boyut: eski tutulacak kopya `ifNotKeptBytes` ile gerçek boyutunu alır). Seçim yoksa ya da özgün tutulacak kopya zaten tutuluyorsa öğe aynen döner.
    public func effective(_ item: CleanItem) -> CleanItem {
        guard item.category == .duplicates, let g = item.groupID, let wanted = keepers[g],
              let original = item.keeperPath, wanted != original else { return item }
        var e = item
        if item.path == wanted {
            e.risk = .info
            e.method = .none
            e.preselect = false
        } else if item.isDuplicateKeeper {
            e.method = .trash
            e.lockReason = item.ifNotKeptLockReason
            e.risk = e.lockReason != nil ? .locked : (item.ifNotKeptRisk ?? .yellow)
            e.preselect = false
            e.ifNotKeptRisk = nil
            e.ifNotKeptLockReason = nil
            if let b = item.ifNotKeptBytes { e.allocatedBytes = b }
            e.ifNotKeptBytes = nil
        }
        e.keeperPath = wanted
        return e
    }

    public static func baseSelectable(_ i: CleanItem) -> Bool {
        !i.isLocked && i.risk != .info && i.risk != .locked && i.method != .none
    }

    /// Grubun etkin tutulacak yolu: kullanıcı seçtiyse o, yoksa taramanın önerdiği.
    public func effectiveKeeperPath(of item: CleanItem) -> String? {
        guard let g = item.groupID else { return nil }
        return keepers[g] ?? item.keeperPath
    }

    public func isKeeper(_ item: CleanItem) -> Bool {
        guard item.groupID != nil, let k = effectiveKeeperPath(of: item) else { return false }
        return k == item.path
    }

    public func isSelectable(_ item: CleanItem) -> Bool {
        Self.baseSelectable(effective(item)) && !isKeeper(item) && !isOrphan(item)
    }

    /// Seçmek grubun bütün kopyalarını seçili bırakır mı? (Bilinmeyen grup: hayır; tutulacak kopya zaten seçilemez.)
    private func wouldSelectWholeGroup(_ item: CleanItem) -> Bool {
        guard let g = item.groupID, let members = groupMembers[g] else { return false }
        return members.allSatisfy { $0.id == item.id || (selectedIDs.contains($0.id) && isSelectable($0)) }
    }

    @discardableResult
    private mutating func trySelect(_ item: CleanItem) -> Bool {
        guard isSelectable(item), !wouldSelectWholeGroup(item) else { return false }
        selectedIDs.insert(item.id)
        return true
    }

    public func isSelected(_ item: CleanItem) -> Bool { selectedIDs.contains(item.id) && isSelectable(item) }

    @discardableResult
    public mutating func toggle(_ item: CleanItem) -> Bool {
        guard isSelectable(item) else { return false }
        if selectedIDs.contains(item.id) { remove(item); return true }
        return trySelect(item)
    }

    public mutating func set(_ item: CleanItem, selected: Bool) {
        guard isSelectable(item) else { return }
        if selected { trySelect(item) } else { remove(item) }
    }

    /// Seçimden çıkarır; uygulama öğesiyse bağlı artıkları da çıkarır.
    private mutating func remove(_ item: CleanItem) {
        selectedIDs.remove(item.id)
        if item.category == .apps && !item.isLeftover { deselectLeftovers(ofApp: item.id) }
    }

    /// "Bunu tut": `item` kendi grubunun tutulacak kopyası olur. Grup dışı öğede etkisiz.
    public mutating func keep(_ item: CleanItem) {
        guard let g = item.groupID, !item.isLocked, item.category == .duplicates else { return }
        keepers[g] = item.path
        selectedIDs.remove(item.id)
    }

    public mutating func clear() { selectedIDs.removeAll() }

    /// Kategorideki seçilebilir yeşil öğelerin hepsi seçili mi?
    public func allGreensSelected(in items: [CleanItem]) -> Bool {
        let greens = items.filter { !$0.isLeftover && effective($0).risk == .green && isSelectable($0) }
        return !greens.isEmpty && greens.allSatisfy { selectedIDs.contains($0.id) }
    }

    /// "Tüm yeşilleri seç" / "Yeşillerin seçimini kaldır".
    public mutating func toggleGreens(in items: [CleanItem]) {
        let greens = items.filter { !$0.isLeftover && effective($0).risk == .green && isSelectable($0) }
        if allGreensSelected(in: items) {
            for g in greens { selectedIDs.remove(g.id) }
        } else {
            for g in greens { trySelect(g) }
        }
    }

    // MARK: Toplu seçim (kategori / grup)

    /// `items` içindeki seçilebilir öğeleri seçer. Kilitli, bilgi, temizlenemez ve tutulacak kopya asla seçilmez;
    /// `needsAuthorization` olanlar seçilebilir (macOS parola ister). Her mükerrer grupta en az bir kopya kalır.
    /// `includeRed == false` ise (etkin) kırmızı öğeler atlanır. Yalnız verilen öğelere dokunur (kategori sınırı).
    public mutating func selectAll(in items: [CleanItem], includeRed: Bool = true) {
        for i in items where isSelectable(i) && !i.isLeftover {
            if !includeRed && effective(i).risk == .red { continue }
            trySelect(i)
        }
        // Artıklar uygulamalarından sonra: yalnız kesin (bundle id) eşleşenler ve uygulaması seçili olanlar.
        for i in items where i.isLeftover && i.leftoverMatch == .bundleID && isSelectable(i) {
            guard let a = i.parentAppID, selectedIDs.contains(a) else { continue }
            if !includeRed && effective(i).risk == .red { continue }
            trySelect(i)
        }
    }

    /// `items` içindeki seçimi kaldırır (başka kategorilere dokunmaz).
    public mutating func deselectAll(in items: [CleanItem]) {
        for i in items { remove(i) }
    }

    /// Bir mükerrer grubun fazla kopyalarını seçer (`members` o grubun üyeleri); tutulacak kopya ve kilitliler hariç, biri kalır.
    public mutating func selectExtraCopies(of members: [CleanItem], includeRed: Bool = true) {
        selectAll(in: members, includeRed: includeRed)
    }

    /// `selectAll(in:includeRed: true)` çağrısının ekleyeceği öğe sayısı ve bunlardan kırmızı olanların sayısı.
    /// Onay iletişim kutusu için; seçimi değiştirmez.
    public func selectAllPreview(in items: [CleanItem]) -> (added: Int, red: Int) {
        var copy = self
        copy.selectAll(in: items, includeRed: true)
        let newIDs = copy.selectedIDs.subtracting(selectedIDs)
        let added = items.filter { newIDs.contains($0.id) }
        return (added.count, added.filter { effective($0).risk == .red }.count)
    }

    /// Seçili öğe var mı? ("Seçimi kaldır" görünürlüğü.)
    public func anySelected(in items: [CleanItem]) -> Bool {
        items.contains { isSelected($0) }
    }

    /// Seçili ve hâlâ seçilebilir öğeler (kaynak sırasıyla), "Bunu tut" seçimi uygulanmış haliyle.
    public func selectedItems(in items: [CleanItem]) -> [CleanItem] {
        items.filter { selectedIDs.contains($0.id) && isSelectable($0) }.map(effective)
    }

    public func selectedBytes(in items: [CleanItem]) -> UInt64 {
        selectedItems(in: items).reduce(0) { $0 &+ $1.allocatedBytes }
    }

    /// Yeni taramadan sonra: olmayan id'leri at, tutulacak yolları koru.
    public mutating func prune(to items: [CleanItem]) {
        let ids = Set(items.map(\.id))
        selectedIDs.formIntersection(ids)
        let groups = Set(items.compactMap(\.groupID))
        keepers = keepers.filter { groups.contains($0.key) }
        register(items)
    }
}
