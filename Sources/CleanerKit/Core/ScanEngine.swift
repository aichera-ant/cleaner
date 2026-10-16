import Foundation

/// Tarama sonucu.
public struct ScanReport: Codable, Sendable {
    public struct ScannerError: Codable, Sendable, Equatable {
        public var scanner: String
        public var message: String
    }

    public struct Dropped: Codable, Sendable, Equatable {
        public var path: String
        public var reason: String
    }

    /// Boyuta göre azalan sırada.
    public var items: [CleanItem]
    public var errors: [ScannerError]
    /// Korunan yol olduğu için atılan öğeler.
    public var dropped: [Dropped]

    public func totalsByCategory() -> [(Category, UInt64)] {
        var t: [Category: UInt64] = [:]
        for i in items { t[i.category, default: 0] &+= i.allocatedBytes }
        return Category.allCases.compactMap { c in t[c].map { (c, $0) } }
    }
}

/// Tarayıcıları paralel çalıştırır, korunan yolları atar, aynı yoldaki tekrarları birleştirir.
public struct ScanEngine: Sendable {
    public var registry: CleanerRegistry

    public init(registry: CleanerRegistry = .makeDefault()) {
        self.registry = registry
    }

    public func scan(_ context: ScanContext, categories: Set<Category>? = nil) async throws -> ScanReport {
        let selected = registry.cleaners.enumerated().filter { _, c in
            categories.map { !$0.isDisjoint(with: c.categories) } ?? true
        }
        typealias Partial = (Int, [CleanItem], ScanReport.ScannerError?)
        var partials: [Partial] = []
        try await withThrowingTaskGroup(of: Partial.self) { group in
            for (index, cleaner) in selected {
                group.addTask {
                    do {
                        return (index, try await cleaner.scan(context), nil)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (index, [], .init(scanner: cleaner.id, message: String(describing: error)))
                    }
                }
            }
            for try await p in group { partials.append(p) }
        }
        partials.sort { $0.0 < $1.0 } // kayıt sırası: aynı yolda ilk kayıtlı tarayıcı kazanır

        var seen = Set<String>()
        var items: [CleanItem] = []
        var dropped: [ScanReport.Dropped] = []
        for (_, list, _) in partials {
            for item in list {
                if let categories, !categories.contains(item.category) { continue }
                if let reason = context.pathPolicy.protectionReason(for: item.url) {
                    dropped.append(.init(path: item.path, reason: reason))
                    continue
                }
                if seen.insert(item.id).inserted { items.append(item) }
            }
        }
        items.sort { ($0.allocatedBytes, $1.path) > ($1.allocatedBytes, $0.path) }
        return ScanReport(items: items, errors: partials.compactMap { $0.2 }, dropped: dropped)
    }
}
