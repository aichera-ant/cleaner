import CleanerKit
import Foundation
import Testing
@testable import CleanerAppCore

@MainActor
@Suite struct AppModelTests {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    func make(items: [CleanItem], clock: Clock) -> (AppModel, FakeScan, FakeTrash) {
        let scan = FakeScan(ScanSnapshot(items: items, scannedAt: clock.date))
        let trash = FakeTrash()
        let model = AppModel(scanService: scan, trashService: trash, now: { clock.date },
                             diskProvider: { DiskInfo(totalBytes: 1000, availableBytes: 400) })
        return (model, scan, trash)
    }

    @Test("açıklama önbelleği: aynı id ama alanları farklı (etkin) öğe önbellekten dönmez")
    func explanationCacheKeyedByItem() {
        let m = AppModel(scanService: FakeScan(ScanSnapshot(items: [], scannedAt: t0)), trashService: FakeTrash(),
                         now: { self.t0 }, diskProvider: { nil })
        let raw = item("x")
        var changed = raw
        changed.method = .command("true")
        changed.risk = .red
        let a = m.explanation(for: raw)
        let b = m.explanation(for: changed)
        #expect(a == ItemExplainer.explain(raw) && b == ItemExplainer.explain(changed))
        #expect(a.recovery != b.recovery)
        #expect(m.explanation(for: raw) == a)
    }

    @Test func refreshDiskReadsProviderAgain() {
        final class Box: @unchecked Sendable { var avail: UInt64 = 400 }
        let box = Box()
        let m = AppModel(scanService: FakeScan(ScanSnapshot(items: [], scannedAt: t0)), trashService: FakeTrash(),
                         now: { self.t0 }, diskProvider: { DiskInfo(totalBytes: 1000, availableBytes: box.avail) })
        #expect(m.disk?.availableBytes == 400)
        box.avail = 900  // Çöp Kutusu uygulama dışında boşaltıldı
        m.refreshDisk()
        #expect(m.disk?.availableBytes == 900)
    }

    @Test func cleanableMatchesSmartSelection() async {
        // Son 30 günde kullanılan proje artığı: yeşil ama varsayılan seçili değil; "güvenle temizlenebilir"e girmez.
        let old = item("old", cat: .projectArtifacts, bytes: 300), recent = item("recent", cat: .projectArtifacts, bytes: 700, preselect: false)
        let (m, _, _) = make(items: [old, recent], clock: Clock(t0))
        await m.startScan()
        #expect(m.cleanableBytes == 300)
        #expect(m.selection.selectedIDs == [old.id])
    }

    @Test func scanAppliesDefaultSelection() async {
        let g = item("g"), l = item("l", lock: "k"), r = item("r", risk: .red)
        let (m, _, _) = make(items: [g, l, r], clock: Clock(t0))
        await m.startScan()
        #expect(m.phase == .ready)
        #expect(m.selection.selectedIDs == [g.id])
        #expect(m.cleanableBytes == g.allocatedBytes)
        #expect(m.progress.fraction == 1 || m.progress.total == 0)
    }

    @Test func scanFailureReturnsToIdle() async {
        struct Boom: Error {}
        let (m, scan, _) = make(items: [], clock: Clock(t0))
        scan.error = Boom()
        await m.startScan()
        #expect(m.phase == .idle)
        #expect(m.errorMessage != nil)
    }

    @Test func confirmWithoutSelectionAndNotReady() async {
        let (m, _, _) = make(items: [item("y", risk: .yellow)], clock: Clock(t0))
        #expect(m.requestConfirm() == .needsRescan) // tarama yok
        await m.startScan()
        #expect(m.requestConfirm() == .nothingSelected)
    }

    @Test func staleScanRequiresRescanAndDoesNotMove() async {
        let clock = Clock(t0)
        let (m, _, trash) = make(items: [item("g")], clock: clock)
        await m.startScan()
        guard case .plan(let plan) = m.requestConfirm() else { Issue.record("plan bekleniyordu"); return }
        clock.date = t0.addingTimeInterval(16 * 60)
        #expect(m.requestConfirm() == .needsRescan)
        let r = await m.confirmMove(plan)
        #expect(r == .needsRescan)
        #expect(trash.calls.isEmpty)
        #expect(m.phase == .ready)
    }

    @Test func moveUsesFreshInMemoryScanAndSelectedIDsOnly() async {
        let g = item("g", bytes: 10), y = item("y", risk: .yellow), l = item("l", lock: "k")
        let (m, _, trash) = make(items: [g, y, l], clock: Clock(t0))
        await m.startScan()
        m.selection.toggle(l) // etkisiz
        guard case .plan(let plan) = m.requestConfirm() else { Issue.record("plan"); return }
        #expect(plan.ids == [g.id])
        _ = await m.confirmMove(plan)
        #expect(trash.calls.count == 1)
        #expect(trash.calls[0].ids == [g.id])
        #expect(trash.calls[0].scan.map(\.id).sorted() == [g.id, y.id, l.id].sorted())
        #expect(trash.calls[0].dryRun == false)
        #expect(m.phase == .result)
        #expect(m.outcome?.freedBytes == 10)
        #expect(m.resultsOutdated)
    }

    @Test func planChangedAfterPreviewIsNotMoved() async {
        let a = item("a"), b = item("b")
        let (m, _, trash) = make(items: [a, b], clock: Clock(t0))
        await m.startScan()
        guard case .plan(let plan) = m.requestConfirm() else { Issue.record("plan"); return }
        m.selection.set(b, selected: false)
        _ = await m.confirmMove(plan)
        #expect(trash.calls.isEmpty)
        #expect(m.phase == .ready)
    }

    @Test func afterMoveResultIsNotTrustedAndDismissClearsIt() async {
        let (m, _, _) = make(items: [item("g")], clock: Clock(t0))
        await m.startScan()
        guard case .plan(let plan) = m.requestConfirm() else { Issue.record("plan"); return }
        _ = await m.confirmMove(plan)
        #expect(m.requestConfirm() == .needsRescan)
        m.dismissResult()
        #expect(m.phase == .idle)
        #expect(m.snapshot == nil)
        #expect(m.selection.selectedIDs.isEmpty)
    }

    @Test func keepersPassedToServiceAndNotSelected() async {
        let k = item("k", cat: .duplicates, risk: .info, group: "g1", keeper: "k")
        let c1 = item("c1", cat: .duplicates, group: "g1", keeper: "k")
        let c2 = item("c2", cat: .duplicates, group: "g1", keeper: "k")
        let (m, _, trash) = make(items: [k, c1, c2], clock: Clock(t0))
        await m.startScan()
        m.selection.keep(c1)
        guard case .plan(let plan) = m.requestConfirm() else { Issue.record("plan"); return }
        #expect(plan.ids == [c2.id])
        _ = await m.confirmMove(plan)
        #expect(trash.calls[0].keepers == ["g1": c1.path])
    }

    @Test func progressEventsAreApplied() async {
        let (m, scan, _) = make(items: [item("a", cat: .xcode, bytes: 7)], clock: Clock(t0))
        scan.events = [.init(scanner: "xcode", categories: [.xcode], event: .started, completed: 0, total: 1)]
        await m.startScan()
        #expect(m.progress.total == 1)
        #expect(m.progress.status(.xcode) == .done(itemCount: 1, bytes: 7))
    }
}
