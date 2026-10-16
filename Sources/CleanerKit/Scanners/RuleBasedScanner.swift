import Foundation

/// `rules.json`'daki bilinen yolları tarar. Kural eklemek için kod değil JSON satırı eklenir.
public struct RuleBasedScanner: Cleaner {
    public let id = "rules"
    /// nil: bağlamdaki kurallar (`context.rules`) kullanılır.
    public let rules: [Rule]?

    public init(rules: [Rule]? = nil) {
        self.rules = rules
    }

    public var categories: Set<Category> {
        // Kurallar bağlamdan geldiğinde hangi kategorilerin çıkacağı önceden bilinmez.
        rules.map { Set($0.map(\.category)) } ?? Set(Category.allCases)
    }

    public func scan(_ context: ScanContext) async throws -> [CleanItem] {
        var items: [CleanItem] = []
        for rule in rules ?? context.rules {
            try context.checkCancellation()
            for url in PathExpander.glob(rule.path, home: context.home) {
                if context.pathPolicy.protectionReason(for: url) != nil { continue }
                let m = try await context.sizeMeter.measure(url)
                let date: DateSignal = m.newestModification.map {
                    .modified(days: DateSignal.days(from: $0, to: context.now))
                } ?? .unknown
                let lock = Self.lockReason(rule.locks, measurement: m, context: context)
                let name = url.lastPathComponent == (rule.path as NSString).lastPathComponent
                    ? rule.name : "\(rule.name) (\(url.lastPathComponent))"
                items.append(CleanItem(
                    category: rule.category,
                    name: name,
                    path: url.path,
                    allocatedBytes: m.allocatedBytes,
                    risk: rule.risk,
                    dateSignal: date,
                    lockReason: lock,
                    note: rule.description,
                    method: rule.method
                ))
            }
        }
        return items
    }

    static func lockReason(_ locks: [LockCondition], measurement: SizeMeasurement, context: ScanContext) -> String? {
        for lock in locks {
            switch lock {
            case .modifiedWithin(let hours):
                if let d = measurement.newestModification, context.now.timeIntervalSince(d) < hours * 3600 {
                    return "son \(Self.format(hours)) saatte değişti"
                }
            case .processRunning(let name):
                if context.signals.processes.isRunning(name) { return "\(name) çalışıyor" }
            }
        }
        return nil
    }

    private static func format(_ h: Double) -> String {
        h == h.rounded() ? String(Int(h)) : String(h)
    }
}
