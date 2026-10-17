import CleanerKit
import Foundation

// Arayüzün çekirdeğe erişimi bu iki protokolün arkasındadır; testte sahtesi verilir.

/// Taze tarama sonucu. Taşıma yalnız bu bellekteki sonuçla yapılır (JSON'dan değil).
public struct ScanSnapshot: Sendable {
    public var items: [CleanItem]
    public var errors: [ScanReport.ScannerError]
    public var dropped: [ScanReport.Dropped]
    public var scannedAt: Date

    public init(items: [CleanItem], errors: [ScanReport.ScannerError] = [],
                dropped: [ScanReport.Dropped] = [], scannedAt: Date) {
        self.items = items
        self.errors = errors
        self.dropped = dropped
        self.scannedAt = scannedAt
    }
}

/// Tarama ilerlemesi (uygulama tipi).
// ip2-core: çekirdekte `ScanProgress` gelince bu tip ondan üretilir (alanlar aynı: scanner, categories, event, completed, total).
public struct AppScanProgress: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case started
        case finished(itemCount: Int, bytes: UInt64)
        case failed(String)
    }

    public var scanner: String
    public var categories: [CleanerKit.Category]
    public var event: Event
    public var completed: Int
    public var total: Int

    public init(scanner: String, categories: [CleanerKit.Category], event: Event, completed: Int, total: Int) {
        self.scanner = scanner
        self.categories = categories
        self.event = event
        self.completed = completed
        self.total = total
    }
}

public protocol ScanService: Sendable {
    func scan(progress: (@Sendable (AppScanProgress) -> Void)?) async throws -> ScanSnapshot
}

public protocol TrashService: Sendable {
    /// - Parameters:
    ///   - keepers: mükerrer grup kimliği -> kullanıcının tutmak istediği yol.
    func trash(ids: [String], scan: [CleanItem], keepers: [String: String], dryRun: Bool) async -> TrashReport
}

/// Gerçek tarama: `ScanContext.live` + `ScanEngine` (tam tarama).
public struct LiveScanService: ScanService {
    public init() {}

    public func scan(progress: (@Sendable (AppScanProgress) -> Void)?) async throws -> ScanSnapshot {
        CloudGuard.disableDatalessMaterializationForProcess()
        let context = try ScanContext.live()
        let engine = ScanEngine()
        let cleaners = engine.registry.cleaners.map { (id: $0.id, categories: Array($0.categories).sorted { $0.rawValue < $1.rawValue }) }
        let total = cleaners.count
        // ip2-core: `ScanEngine.scan(..., progress:)` gelince gerçek ilerleme buradan akar; şimdilik yalnız başla/bitti.
        if let progress {
            for c in cleaners {
                progress(.init(scanner: c.id, categories: c.categories, event: .started, completed: 0, total: total))
            }
        }
        let report = try await engine.scan(context)
        if let progress {
            for (i, c) in cleaners.enumerated() {
                let mine = report.items.filter { c.categories.contains($0.category) }
                let bytes = mine.reduce(UInt64(0)) { $0 &+ $1.allocatedBytes }
                progress(.init(scanner: c.id, categories: c.categories,
                               event: .finished(itemCount: mine.count, bytes: bytes),
                               completed: i + 1, total: total))
            }
        }
        return ScanSnapshot(items: report.items, errors: report.errors, dropped: report.dropped, scannedAt: context.now)
    }
}

/// Gerçek taşıma: yalnız `Trasher.trash(ids:scan:dryRun:)`, bellekteki taze tarama sonucuyla.
public struct LiveTrashService: TrashService {
    public init() {}

    public func trash(ids: [String], scan: [CleanItem], keepers: [String: String], dryRun: Bool) async -> TrashReport {
        CloudGuard.disableDatalessMaterializationForProcess()
        do {
            let context = try ScanContext.live()
            // ip2-core: `Trasher(..., privilegedRecycler: WorkspaceRecycler())` (macOS korumalı uygulamalar için parola/Touch ID).
            let trasher = Trasher(policy: context.pathPolicy, commands: context.signals.commands)
            // ip2-core: `trasher.trash(ids:scan:dryRun:keepers:)`; şimdilik keepers geçilmez (arayüzde durumda tutulur).
            _ = keepers
            return await trasher.trash(ids: ids, scan: scan, dryRun: dryRun)
        } catch {
            let refused = ids.map { TrashReport.Refused(id: $0, path: "", reason: "hazırlık başarısız: \(error.localizedDescription)") }
            return TrashReport(dryRun: dryRun, done: [], refused: refused)
        }
    }
}
