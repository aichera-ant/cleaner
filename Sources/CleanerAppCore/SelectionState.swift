import CleanerKit
import Foundation

/// Seçim durumu. Kurallar:
/// - Kilitli, `.info`, temizlenemez (`method == .none`) ve tutulacak kopya seçilemez.
/// - Varsayılan seçim `isDefaultSelected` (kırmızı/kilitli asla).
/// - "Bunu tut": grup için tutulacak yol durumda tutulur; o kopya seçilemez, seçiliyse seçimden çıkar.
public struct SelectionState: Sendable, Equatable {
    public private(set) var selectedIDs: Set<String> = []
    /// Mükerrer grup kimliği -> kullanıcının tutmak istediği yol.
    // ip2-core: bu sözlük `Trasher.trash(ids:scan:dryRun:keepers:)`'a geçecek (canlı servis şimdilik geçmiyor).
    public private(set) var keepers: [String: String] = [:]

    public init() {}

    /// Varsayılan seçimle başlar.
    public init(defaultsFrom items: [CleanItem]) {
        for i in items where i.isDefaultSelected && Self.baseSelectable(i) { selectedIDs.insert(i.id) }
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
        Self.baseSelectable(item) && !isKeeper(item)
    }

    public func isSelected(_ item: CleanItem) -> Bool { selectedIDs.contains(item.id) && isSelectable(item) }

    @discardableResult
    public mutating func toggle(_ item: CleanItem) -> Bool {
        guard isSelectable(item) else { return false }
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
        return true
    }

    public mutating func set(_ item: CleanItem, selected: Bool) {
        guard isSelectable(item) else { return }
        if selected { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
    }

    /// "Bunu tut": `item` kendi grubunun tutulacak kopyası olur. Grup dışı öğede etkisiz.
    public mutating func keep(_ item: CleanItem) {
        guard let g = item.groupID, !item.isLocked else { return }
        keepers[g] = item.path
        selectedIDs.remove(item.id)
    }

    public mutating func clear() { selectedIDs.removeAll() }

    /// Kategorideki seçilebilir yeşil öğelerin hepsi seçili mi?
    public func allGreensSelected(in items: [CleanItem]) -> Bool {
        let greens = items.filter { $0.risk == .green && isSelectable($0) }
        return !greens.isEmpty && greens.allSatisfy { selectedIDs.contains($0.id) }
    }

    /// "Tüm yeşilleri seç" / "Yeşillerin seçimini kaldır".
    public mutating func toggleGreens(in items: [CleanItem]) {
        let greens = items.filter { $0.risk == .green && isSelectable($0) }
        if allGreensSelected(in: items) {
            for g in greens { selectedIDs.remove(g.id) }
        } else {
            for g in greens { selectedIDs.insert(g.id) }
        }
    }

    /// Seçili ve hâlâ seçilebilir öğeler (kaynak sırasıyla).
    public func selectedItems(in items: [CleanItem]) -> [CleanItem] {
        items.filter { selectedIDs.contains($0.id) && isSelectable($0) }
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
    }
}
