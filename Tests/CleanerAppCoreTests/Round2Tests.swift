import CleanerKit
import Foundation
import Testing
@testable import CleanerAppCore

@Suite struct Round2Tests {
    func cmd(_ n: String) -> CleanItem { item(n, method: .command("echo \(n)")) }

    @Test func permanentDeleteWarning() {
        #expect(TrashPlan(selected: [item("a")]).permanentDeleteWarning == nil)
        #expect(TrashPlan(selected: [item("a")]).confirmButtonTitle == "Çöp Kutusu'na taşı")
        let one = TrashPlan(selected: [item("a"), cmd("npm")])
        #expect(one.permanentDeleteWarning == "1 öğe kalıcı silinir, geri alınamaz: npm.")
        #expect(one.confirmButtonTitle == "Taşı ve temizle")
        let many = TrashPlan(selected: ["c1", "c2", "c3", "c4", "c5"].map(cmd))
        let w = many.permanentDeleteWarning ?? ""
        #expect(w.hasPrefix("5 öğe kalıcı silinir, geri alınamaz: "))
        #expect(w.hasSuffix(" ve 2 daha."))
    }

    @Test func keeperBytesOverrideOnlyWhenOriginalKeeperBecomesTrashable() {
        var k = item("k", cat: .duplicates, bytes: 0, risk: .info, method: .none, group: "g", keeper: "k", ifNotKeptRisk: .yellow)
        k.ifNotKeptBytes = 5000
        let c1 = item("c1", cat: .duplicates, bytes: 5000, group: "g", keeper: "k")
        var sel = SelectionState(defaultsFrom: [k, c1])
        #expect(sel.effective(k).allocatedBytes == 0) // varsayılan: tutulacak, boyut 0 (çift sayım yok)
        sel.keep(c1)
        let e = sel.effective(k)
        #expect(e.allocatedBytes == 5000 && e.method == .trash && e.ifNotKeptBytes == nil)
        #expect(sel.effective(c1).allocatedBytes == 5000)
        sel.toggle(k)
        #expect(sel.selectedBytes(in: [k, c1]) == 5000)
        #expect(Summaries.totalBytes([k, c1]) == 5000) // ham toplam çift sayılmaz
    }

    @Test func planDiffersWhenKeepersChange() {
        let a = item("a")
        #expect(TrashPlan(selected: [a], keepers: [:]) == TrashPlan(selected: [a], keepers: [:]))
        #expect(TrashPlan(selected: [a], keepers: [:]) != TrashPlan(selected: [a], keepers: ["g": "/tmp/cleaner-test/x"]))
    }

    @MainActor @Test func modelRejectsPlanWhenKeeperChangedAfterPreview() async {
        let k = item("k", cat: .duplicates, bytes: 0, risk: .info, method: .none, group: "g", keeper: "k", ifNotKeptRisk: .yellow)
        let c1 = item("c1", cat: .duplicates, group: "g", keeper: "k")
        let c2 = item("c2", cat: .duplicates, group: "g", keeper: "k")
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let trash = FakeTrash()
        let m = AppModel(scanService: FakeScan(ScanSnapshot(items: [k, c1, c2], scannedAt: clock.date)), trashService: trash,
                         now: { clock.date }, diskProvider: { nil })
        await m.startScan()
        m.selection.set(c1, selected: true)
        guard case .plan(let plan) = m.requestConfirm() else { Issue.record("plan yok"); return }
        m.selection.keep(c2) // seçili kimlikler aynı kalır, yalnız keeper değişir
        _ = await m.confirmMove(plan)
        #expect(trash.calls.isEmpty)
    }

    @Test func revealOpensParentForDatalessOrCloud() {
        let home = URL(fileURLWithPath: "/tmp/cleaner-test-home")
        func g(dataless: Set<String> = [], notCurrent: Set<String> = []) -> CloudGuard {
            CloudGuard(home: home, probes: .init(
                isDataless: { dataless.contains($0.path) },
                isDownloadedCurrent: { notCurrent.contains($0.path) ? false : nil },
                isRegularFile: { _ in true }))
        }
        #expect(RevealTarget.decide(path: "/tmp/cleaner-test-home/a/b.txt", guardian: g()) == .select("/tmp/cleaner-test-home/a/b.txt"))
        #expect(RevealTarget.decide(path: "/tmp/cleaner-test-home/a/b.txt", guardian: g(dataless: ["/tmp/cleaner-test-home/a/b.txt"]))
                == .openParent("/tmp/cleaner-test-home/a"))
        #expect(RevealTarget.decide(path: "/tmp/cleaner-test-home/a/c.txt", guardian: g(notCurrent: ["/tmp/cleaner-test-home/a/c.txt"]))
                == .openParent("/tmp/cleaner-test-home/a"))
        #expect(RevealTarget.decide(path: "/tmp/cleaner-test-home/Library/Mobile Documents/x/y.pdf", guardian: g())
                == .openParent("/tmp/cleaner-test-home/Library/Mobile Documents/x"))
    }
}
