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
public struct AppScanProgress: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case started
        case finished(itemCount: Int, bytes: UInt64)
        case failed(String)
    }

    public var scanner: String
    public var categories: [ItemCategory]
    public var event: Event
    public var completed: Int
    public var total: Int

    /// Çekirdeğin `ScanProgress`inden üretir.
    public init(_ p: ScanProgress) {
        let event: Event
        switch p.event {
        case .started: event = .started
        case .finished(let n, let b): event = .finished(itemCount: n, bytes: b)
        case .failed(let m): event = .failed(m)
        }
        self.init(scanner: p.scanner, categories: p.categories, event: event, completed: p.completed, total: p.total)
    }

    public init(scanner: String, categories: [ItemCategory], event: Event, completed: Int, total: Int) {
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
        // Çekirdek bu kapanışı eşzamanlı iş parçacıklarından çağırır; AppModel sıraya koyup MainActor'a aktarır.
        var coreProgress: (@Sendable (ScanProgress) -> Void)?
        if let sink = progress {
            coreProgress = { @Sendable (p: ScanProgress) in sink(AppScanProgress(p)) }
        }
        let report = try await engine.scan(context, progress: coreProgress)
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
            // Yetkili taşıyıcı yalnız çekirdeğin doğruladığı `needsAuthorization` uygulama paketi için kullanılır:
            // Finder'a Apple Event ile taşıtılır, Finder gerekirse parola ya da Touch ID ister.
            // (`NSWorkspace.recycle` root sahipli paketlerde yetki istemeden "izin yok" verdiği için kullanılmaz.)
            let trasher = Trasher(policy: context.pathPolicy, commands: context.signals.commands,
                                  privilegedRecycler: FinderRecycler())
            return await trasher.trash(ids: ids, scan: scan, dryRun: dryRun, keepers: keepers)
        } catch {
            let refused = ids.map { TrashReport.Refused(id: $0, path: "", reason: "hazırlık başarısız: \(error.localizedDescription)") }
            return TrashReport(dryRun: dryRun, done: [], refused: refused)
        }
    }
}
