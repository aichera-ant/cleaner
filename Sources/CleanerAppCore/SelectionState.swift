import CleanerKit
import Foundation

/// Seçim durumu. Kurallar:
/// - Kilitli, `.info`, temizlenemez (`method == .none`) ve tutulacak kopya seçilemez.
/// - Varsayılan seçim `isDefaultSelected` (kırmızı/kilitli asla).
/// - "Bunu tut": grup için tutulacak yol durumda tutulur; o kopya seçilemez, seçiliyse seçimden çıkar.
///   Taramanın önerdiği özgün tutulacak kopya taşınabilir olur (`effective(_:)`, çekirdekteki `Trasher.applyKeepers` ile
///   aynı kural): riski `ifNotKeptRisk` (yoksa sarı), kilidi `ifNotKeptLockReason`; varsayılan seçimde değildir.
/// - Bir grubun bütün kopyaları seçilemez: en az biri kalır.
public struct SelectionState: Sendable, Equatable {
    public private(set) var selectedIDs: Set<String> = []
    /// Mükerrer grup kimliği -> kullanıcının tutmak istediği yol.
    /// `Trasher.trash(ids:scan:dryRun:keepers:)`'a olduğu gibi geçer.
    public private(set) var keepers: [String: String] = [:]
    /// Mükerrer grup kimliği -> taramadaki (özgün) üyeler. "Hiç kopya kalmasın" engeli için.
    private var groupMembers: [String: [CleanItem]] = [:]

    public init() {}

    /// Varsayılan seçimle başlar.
    public init(defaultsFrom items: [CleanItem]) {
        register(items)
        for i in items where i.isDefaultSelected && Self.baseSelectable(i) { trySelect(i) }
    }

    /// Grup üyelerini tanır (yeni tarama sonucu).
    public mutating func register(_ items: [CleanItem]) {
        groupMembers = [:]
        for i in items where i.category == .duplicates {
            if let g = i.groupID { groupMembers[g, default: []].append(i) }
        }
    }

    /// Kullanıcının "Bunu tut" seçimi uygulanmış öğe (çekirdekteki `applyKeepers` ile aynı alan değişiklikleri;
    /// boyut değişmez). Seçim yoksa ya da özgün tutulacak kopya zaten tutuluyorsa öğe aynen döner.
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
        Self.baseSelectable(effective(item)) && !isKeeper(item)
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
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id); return true }
        return trySelect(item)
    }

    public mutating func set(_ item: CleanItem, selected: Bool) {
        guard isSelectable(item) else { return }
        if selected { trySelect(item) } else { selectedIDs.remove(item.id) }
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
        let greens = items.filter { effective($0).risk == .green && isSelectable($0) }
        return !greens.isEmpty && greens.allSatisfy { selectedIDs.contains($0.id) }
    }

    /// "Tüm yeşilleri seç" / "Yeşillerin seçimini kaldır".
    public mutating func toggleGreens(in items: [CleanItem]) {
        let greens = items.filter { effective($0).risk == .green && isSelectable($0) }
        if allGreensSelected(in: items) {
            for g in greens { selectedIDs.remove(g.id) }
        } else {
            for g in greens { trySelect(g) }
        }
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
