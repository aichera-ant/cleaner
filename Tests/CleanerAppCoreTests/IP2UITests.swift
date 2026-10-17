import CleanerKit
import Foundation
import Testing
@testable import CleanerAppCore

/// Çekirdek API'sine bağlama: ilerleme dönüşümü, yetki rozeti, "Bunu tut" anlamı.
@MainActor
@Suite struct IP2UITests {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    // Özgün tutulacak kopya k (git'te takipli olurdu), c1 ve c2 kopyalar.
    func group(kLock: String? = nil, kRisk: Risk? = .red) -> (k: CleanItem, c1: CleanItem, c2: CleanItem) {
        (item("k", cat: .duplicates, risk: .info, method: .none, group: "g", keeper: "k", ifNotKeptRisk: kRisk, ifNotKeptLock: kLock),
         item("c1", cat: .duplicates, group: "g", keeper: "k"),
         item("c2", cat: .duplicates, group: "g", keeper: "k"))
    }

    // MARK: 1. ilerleme

    @Test func appProgressFromCoreProgress() {
        let core = ScanProgress(scanner: "xcode", categories: [.xcode, .caches], event: .finished(itemCount: 3, bytes: 99),
                                completed: 2, total: 7)
        let p = AppScanProgress(core)
        #expect(p == AppScanProgress(scanner: "xcode", categories: [.xcode, .caches], event: .finished(itemCount: 3, bytes: 99), completed: 2, total: 7))
        #expect(AppScanProgress(ScanProgress(scanner: "a", categories: [.docker], event: .started, completed: 0, total: 1)).event == .started)
        #expect(AppScanProgress(ScanProgress(scanner: "a", categories: [.docker], event: .failed("x"), completed: 1, total: 1)).event == .failed("x"))
    }

    @Test func progressOrderPreservedAndModelFinishes() async {
        let scan = FakeScan(ScanSnapshot(items: [], scannedAt: t0))
        scan.events = [
            .init(scanner: "a", categories: [.docker], event: .started, completed: 0, total: 2),
            .init(scanner: "a", categories: [.docker], event: .finished(itemCount: 1, bytes: 5), completed: 1, total: 2),
        ]
        let m = AppModel(scanService: scan, trashService: FakeTrash(), now: { self.t0 }, diskProvider: { nil })
        await m.startScan()
        #expect(m.phase == .ready)
        #expect(m.progress.total == 2)
    }

    // MARK: 3. yetkilendirme

    @Test func needsAuthorizationBadgeAndPlan() {
        let a = item("App", cat: .apps, risk: .yellow, auth: true)
        let b = item("Other", cat: .apps, risk: .yellow, auth: false)
        let c = item("Plain", cat: .apps, risk: .yellow)
        #expect(Fmt.needsAuthorization(a))
        #expect(!Fmt.needsAuthorization(b) && !Fmt.needsAuthorization(c))
        let plan = TrashPlan(selected: [a, b, c])
        #expect(plan.authorizationItems.map(\.id) == [a.id])
        #expect(TrashPlan(selected: [b, c]).authorizationItems.isEmpty)
        // Yetki isteyen öğe varsayılan seçimde olmaz.
        let g = item("G", cat: .apps, auth: true)
        #expect(SelectionState(defaultsFrom: [g]).selectedIDs.isEmpty)
    }

    // MARK: 4. kategori

    @Test func itemCategoryIsTheCoreCategory() {
        let c: ItemCategory = .duplicates
        #expect(CategoryInfo.info(for: c).category == CleanerKit.Category.duplicates)
    }

    // MARK: 5. "Bunu tut"

    @Test func keepingAnotherCopyMakesOriginalKeeperSelectableWithIfNotKeptRisk() {
        let (k, c1, c2) = group()
        var sel = SelectionState(defaultsFrom: [k, c1, c2])
        #expect(!sel.isSelectable(k))
        sel.keep(c1)
        let e = sel.effective(k)
        #expect(e.risk == .red && e.method == .trash && e.lockReason == nil && e.keeperPath == c1.path)
        #expect(sel.isSelectable(k))
        #expect(!sel.isSelected(k)) // varsayılan seçimde değil
        #expect(!sel.isKeeper(k) && sel.isKeeper(c1))
        #expect(Fmt.riskLabel(e) == "Karar senin")
        let t = sel.toggle(k)
        #expect(t)
        #expect(sel.selectedItems(in: [k, c1, c2]).map(\.risk).contains(.red))
        // Tutulan kopya taşınamaz ve seçimden çıkar.
        #expect(!sel.isSelectable(c1) && !sel.isSelected(c1))
        #expect(sel.effective(c1).risk == .info && sel.effective(c1).method == .none)
    }

    @Test func ifNotKeptRiskDefaultsToYellow() {
        let (k, c1, c2) = group(kRisk: nil)
        var sel = SelectionState(defaultsFrom: [k, c1, c2])
        sel.keep(c2)
        #expect(sel.effective(k).risk == .yellow)
    }

    @Test func ifNotKeptLockKeepsOriginalKeeperUnselectable() {
        let (k, c1, c2) = group(kLock: "git'te takipli")
        var sel = SelectionState(defaultsFrom: [k, c1, c2])
        sel.keep(c1)
        let e = sel.effective(k)
        #expect(e.isLocked && e.lockReason == "git'te takipli" && e.risk == .locked)
        #expect(!sel.isSelectable(k))
        let t = sel.toggle(k)
        #expect(!t)
    }

    @Test func keepingTheOriginalKeeperAgainRestoresEverything() {
        let (k, c1, c2) = group()
        var sel = SelectionState(defaultsFrom: [k, c1, c2])
        sel.keep(c1)
        sel.toggle(k)
        #expect(sel.isSelected(k))
        sel.keep(k)
        #expect(sel.effective(k) == k && sel.effective(c1) == c1)
        #expect(!sel.isSelected(k) && sel.isKeeper(k))
        #expect(sel.isSelected(c1) == false && sel.isSelectable(c1))
    }

    @Test func switchingKeeperBetweenCopies() {
        let (k, c1, c2) = group()
        var sel = SelectionState(defaultsFrom: [k, c1, c2])
        sel.keep(c1)
        sel.keep(c2)
        #expect(sel.isKeeper(c2) && !sel.isKeeper(c1))
        #expect(sel.effective(c1) == c1.with(keeper: c2.path))
        #expect(sel.isSelectable(c1) && sel.isSelectable(k))
    }

    @Test func wholeGroupCannotBeSelected() {
        let (k, c1, c2) = group()
        var sel = SelectionState(defaultsFrom: [k, c1, c2])
        sel.keep(c1)
        let t1 = sel.toggle(k), t2 = sel.toggle(c2)
        #expect(t1 && t2)
        sel.keep(c2) // c2 seçimden çıkar; k seçili kalır, c1 artık seçilebilir ama tutulan c2 ile birlikte grup tükenmez
        #expect(!sel.isSelected(c2) && sel.isSelected(k))
        let t3 = sel.toggle(c1)
        #expect(t3)
        #expect(Set(sel.selectedItems(in: [k, c1, c2]).map(\.id)) == [k.id, c1.id])
    }

    @Test func registeredGroupBlocksSelectingEveryCopy() {
        // Tutulacak kopyası grup üyesi olmayan (bozuk veri) grupta bile bütün kopyalar seçilemez.
        let a = item("a", cat: .duplicates, group: "g", keeper: "zz")
        let b = item("b", cat: .duplicates, group: "g", keeper: "zz")
        var sel = SelectionState(defaultsFrom: [a, b])
        #expect(sel.selectedIDs.count == 1)
        let other = sel.selectedIDs.contains(a.id) ? b : a
        let t = sel.toggle(other)
        #expect(!t)
        #expect(sel.selectedIDs.count == 1)
        sel.toggleGreens(in: [a, b])
        #expect(sel.selectedIDs.count < 2)
    }

    @Test func cleanableBytesAndPlanUseEffectiveRisk() {
        var (k, c1, c2) = group()
        k.allocatedBytes = 500
        _ = (c1, c2)
        var sel = SelectionState(defaultsFrom: [k, c1, c2])
        #expect(Summaries.cleanableBytes([k, c1, c2], selection: sel) == c1.allocatedBytes + c2.allocatedBytes)
        sel.keep(c1)
        // k artık sarı/kırmızı: "güvenle temizlenebilir" değil; c1 tutuluyor.
        #expect(Summaries.cleanableBytes([k, c1, c2], selection: sel) == c2.allocatedBytes)
        sel.toggle(k)
        let plan = TrashPlan(selected: sel.selectedItems(in: [k, c1, c2]))
        #expect(plan.nonGreen.map(\.id) == [k.id])
    }

    @Test func modelPassesKeepersAndOriginalScanToService() async {
        let (k, c1, c2) = group()
        let clock = Clock(t0)
        let scan = FakeScan(ScanSnapshot(items: [k, c1, c2], scannedAt: clock.date))
        let trash = FakeTrash()
        let m = AppModel(scanService: scan, trashService: trash, now: { clock.date }, diskProvider: { nil })
        await m.startScan()
        m.selection.keep(c1)
        m.selection.set(k, selected: true)
        guard case .plan(let plan) = m.requestConfirm() else { Issue.record("plan yok"); return }
        #expect(Set(plan.ids) == [k.id, c2.id])
        _ = await m.confirmMove(plan, dryRun: true)
        let call = trash.calls[0]
        #expect(call.keepers == ["g": c1.path])
        #expect(call.scan == [k, c1, c2]) // özgün tarama sonucu; dönüşümü çekirdek yapar
        #expect(Set(call.ids) == [k.id, c2.id] && call.dryRun)
    }
}

extension CleanItem {
    fileprivate func with(keeper: String) -> CleanItem { var c = self; c.keeperPath = keeper; return c }
}
