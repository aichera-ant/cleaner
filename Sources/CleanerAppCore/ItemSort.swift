import CleanerKit
import Foundation

/// Kategori listelerinin sıralama seçenekleri.
public enum ItemSort: String, Sendable, CaseIterable, Identifiable {
    case sizeDescending, sizeAscending, oldestFirst, nameAscending, risk

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sizeDescending: "Boyut (büyükten küçüğe)"
        case .sizeAscending: "Boyut (küçükten büyüğe)"
        case .oldestFirst: "Son kullanım (en eski önce)"
        case .nameAscending: "Ad (A-Z)"
        case .risk: "Risk"
        }
    }

    /// Saf sıralama. Tarihi bilinmeyen öğeler sona; eşitlikte ad, sonra yol.
    public func sorted(_ items: [CleanItem]) -> [CleanItem] {
        items.sorted { a, b in
            if let r = primary(a, b) { return r }
            let c = a.name.localizedStandardCompare(b.name)
            if c != .orderedSame { return c == .orderedAscending }
            return a.path < b.path
        }
    }

    /// nil: eşit (ad ile devam edilir).
    private func primary(_ a: CleanItem, _ b: CleanItem) -> Bool? {
        switch self {
        case .sizeDescending: return a.allocatedBytes == b.allocatedBytes ? nil : a.allocatedBytes > b.allocatedBytes
        case .sizeAscending: return a.allocatedBytes == b.allocatedBytes ? nil : a.allocatedBytes < b.allocatedBytes
        case .oldestFirst:
            switch (a.dateSignal.days, b.dateSignal.days) {
            case let (x?, y?): return x == y ? nil : x > y
            case (nil, nil): return nil
            case (_?, nil): return true
            case (nil, _?): return false
            }
        case .nameAscending: return nil
        case .risk:
            let x = a.isLocked ? Risk.locked : a.risk, y = b.isLocked ? Risk.locked : b.risk
            return x == y ? nil : x < y
        }
    }
}
