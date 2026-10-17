import CleanerKit
import Foundation
import Observation

/// Uygulamanın tek görünüm modeli. SwiftUI'den bağımsızdır; servisler sahtelenebilir.
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case moving
        case result
    }

    public enum ConfirmOutcome: Equatable {
        case plan(TrashPlan)
        /// Tarama 15 dakikadan eski ya da hiç yok: önce yeniden tara.
        case needsRescan
        case nothingSelected
    }

    public private(set) var phase: Phase = .idle
    public private(set) var snapshot: ScanSnapshot?
    public var selection = SelectionState()
    public private(set) var progress = ScanProgressState()
    public private(set) var outcome: TrashOutcome?
    public private(set) var errorMessage: String?
    public private(set) var disk: DiskInfo?
    /// Taşıma sonrası eski tarama sonucu güncel kabul edilmez.
    public private(set) var resultsOutdated = false
    /// Son taşımada Çöp Kutusu'na giden öğe sayısı (bilgi).
    public private(set) var lastScanItemsForOutcome: [CleanItem] = []

    private let scanService: any ScanService
    private let trashService: any TrashService
    private let now: @Sendable () -> Date
    private let diskProvider: @Sendable () -> DiskInfo?
    private var scanTask: Task<Void, Never>?

    public init(scanService: any ScanService, trashService: any TrashService,
                now: @escaping @Sendable () -> Date = { Date() },
                diskProvider: @escaping @Sendable () -> DiskInfo? = { DiskInfo.current() }) {
        self.scanService = scanService
        self.trashService = trashService
        self.now = now
        self.diskProvider = diskProvider
        self.disk = diskProvider()
    }

    // MARK: Okuma

    public var items: [CleanItem] { snapshot?.items ?? [] }
    public var selectedItems: [CleanItem] { selection.selectedItems(in: items) }
    public var selectedBytes: UInt64 { Summaries.totalBytes(selectedItems) }
    public var cleanableBytes: UInt64 { Summaries.cleanableBytes(items, selection: selection) }

    public func isStale(at date: Date? = nil) -> Bool {
        guard let s = snapshot else { return true }
        return ScanFreshness.isStale(scannedAt: s.scannedAt, now: date ?? now())
    }

    // MARK: Tarama

    /// Taramayı başlatır; bitince döner (testte beklenebilir). İptal edilirse `idle`e döner.
    public func startScan() async {
        guard phase != .scanning, phase != .moving else { return }
        errorMessage = nil
        outcome = nil
        progress = ScanProgressState()
        phase = .scanning
        let service = scanService
        let task = Task { [weak self] in
            do {
                let snap = try await service.scan(progress: { [weak self] p in
                    Task { @MainActor in self?.apply(progress: p) }
                })
                try Task.checkCancellation()
                self?.finishScan(snap)
            } catch is CancellationError {
                self?.cancelled()
            } catch {
                self?.failed(error)
            }
        }
        scanTask = task
        await task.value
        scanTask = nil
    }

    public func cancelScan() { scanTask?.cancel() }

    private func apply(progress p: AppScanProgress) {
        guard phase == .scanning else { return }
        progress.apply(p)
    }

    private func finishScan(_ snap: ScanSnapshot) {
        snapshot = snap
        resultsOutdated = false
        selection = SelectionState(defaultsFrom: snap.items)
        progress.finish(items: snap.items)
        disk = diskProvider()
        phase = .ready
    }

    private func cancelled() {
        phase = snapshot == nil ? .idle : .ready
    }

    private func failed(_ error: Error) {
        errorMessage = "Tarama başarısız: \(error.localizedDescription)"
        phase = snapshot == nil ? .idle : .ready
    }

    // MARK: Taşıma

    /// "Önizle": onay sayfasının içeriği ya da yeniden tarama isteği.
    public func requestConfirm() -> ConfirmOutcome {
        guard phase == .ready, !resultsOutdated else { return .needsRescan }
        if isStale() { return .needsRescan }
        let sel = selectedItems
        guard !sel.isEmpty else { return .nothingSelected }
        return .plan(TrashPlan(selected: sel))
    }

    /// Onaydan sonra taşır. `plan` onay sayfasında gösterilen plandır; seçim arada değiştiyse taşınmaz.
    /// Tarama yine 15 dakikadan eskiyse hiçbir şey yapılmaz (`needsRescan`).
    @discardableResult
    public func confirmMove(_ plan: TrashPlan, dryRun: Bool = false) async -> ConfirmOutcome {
        guard phase == .ready, !resultsOutdated, let snap = snapshot else { return .needsRescan }
        if ScanFreshness.isStale(scannedAt: snap.scannedAt, now: now()) { return .needsRescan }
        let current = TrashPlan(selected: selectedItems)
        guard current == plan, !plan.ids.isEmpty else { return .plan(current) }
        phase = .moving
        // Yalnız taze tarama sonucu (bellekteki) verilir.
        let report = await trashService.trash(ids: plan.ids, scan: snap.items, keepers: selection.keepers, dryRun: dryRun)
        outcome = TrashOutcome(report: report, items: snap.items)
        if !dryRun {
            // Taşıma sonrası tarama sonucu güncel değil: yeniden tara.
            resultsOutdated = true
            selection.clear()
            disk = diskProvider()
        }
        phase = .result
        return .plan(plan)
    }

    /// Sonuç ekranından çıkış: eski sonuç gösterilmez, yeniden tara istenir.
    public func dismissResult() {
        guard phase == .result else { return }
        if resultsOutdated { snapshot = nil }
        outcome = nil
        phase = snapshot == nil ? .idle : .ready
    }

    public func clearError() { errorMessage = nil }
}
