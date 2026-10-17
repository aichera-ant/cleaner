import CleanerKit
import Foundation
import Testing
@testable import CleanerAppCore

@Suite struct SummaryTests {
    @Test func totalsAndCleanable() {
        let items = [
            item("a", cat: .caches, bytes: 300),
            item("b", cat: .caches, bytes: 200, risk: .yellow),
            item("c", cat: .xcode, bytes: 500, lock: "k"),
            item("d", cat: .xcode, bytes: 50),
        ]
        let t = Summaries.totals(items)
        #expect(t[.caches] == 500)
        #expect(t[.xcode] == 550)
        #expect(Summaries.cleanableBytes(items) == 350)
        let rc = Summaries.riskCounts(items)
        #expect(rc.green == 2 && rc.yellow == 1 && rc.locked == 1 && rc.red == 0)
    }

    @Test func categoryItemsSortedBySize() {
        let items = [item("a", bytes: 10), item("b", bytes: 30), item("c", bytes: 20), item("x", cat: .xcode, bytes: 99)]
        #expect(Summaries.items(in: .caches, items).map(\.name) == ["b", "c", "a"])
    }

    @Test func duplicateGroups() {
        let k = item("k", cat: .duplicates, bytes: 100, risk: .info, group: "g1", keeper: "k")
        let a = item("a", cat: .duplicates, bytes: 100, group: "g1", keeper: "k")
        let k2 = item("k2", cat: .duplicates, bytes: 1000, risk: .info, group: "g2", keeper: "k2")
        let b = item("b", cat: .duplicates, bytes: 1000, group: "g2", keeper: "k2")
        let groups = Summaries.duplicateGroups([k, a, k2, b, item("other")])
        #expect(groups.map(\.id) == ["g2", "g1"])
        #expect(groups[1].members.count == 2)
        #expect(!groups[0].untouchable)
    }

    @Test func planSplitsCommandAndNonGreen() {
        let trashA = item("a", cat: .xcode, bytes: 300)
        let trashY = item("y", cat: .caches, bytes: 200, risk: .yellow)
        let cmd = item("npm", cat: .caches, bytes: 400, method: .command("npm cache clean --force"))
        let plan = TrashPlan(selected: [trashA, trashY, cmd])
        #expect(plan.itemCount == 3)
        #expect(plan.totalBytes == 900)
        #expect(plan.commandItems.map(\.name) == ["npm"])
        #expect(plan.commandBytes == 400)
        #expect(plan.trashCount == 2)
        #expect(plan.nonGreen.map(\.name) == ["y"])
        #expect(plan.trashGroups.map(\.category) == [.xcode, .caches])
    }

    @Test func freshnessThreshold() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(!ScanFreshness.isStale(scannedAt: t0, now: t0.addingTimeInterval(15 * 60)))
        #expect(ScanFreshness.isStale(scannedAt: t0, now: t0.addingTimeInterval(15 * 60 + 1)))
    }

    @Test func outcomeSummarizes() {
        let a = item("a", bytes: 300), b = item("b", bytes: 200), c = item("c", bytes: 50)
        let report = TrashReport(
            dryRun: false,
            done: [makeDone(id: a.id, path: a.path, bytes: 300, action: "trashed"),
                   makeDone(id: b.id, path: b.path, bytes: 200, action: "command", detail: "x")],
            refused: [.init(id: c.id, path: "", reason: "kilitli: kullanımda")],
            skipped: [.init(id: "zz", path: "/p/q", reason: "üst öğeyle birlikte")])
        let o = TrashOutcome(report: report, items: [a, b, c])
        #expect(o.freedBytes == 500 && o.trashedBytes == 300 && o.commandBytes == 200)
        #expect(o.refused.first?.name == "c" && o.refused.first?.path == c.path)
        #expect(o.refused.first?.reason == "kilitli: kullanımda")
        #expect(o.skipped.first?.name == "q")
    }

    @Test func outcomeHeadlineAndFullDiskAccess() {
        let a = item("a", bytes: 300), b = item("b", bytes: 200), c = item("c", bytes: 50)
        let ok = TrashOutcome(report: TrashReport(dryRun: false, done: [makeDone(id: a.id, path: a.path, bytes: 300, action: "trashed")],
                                                  refused: []), items: [a])
        #expect(ok.failedCount == 0 && ok.headline == "Temizlik tamamlandı" && !ok.needsFullDiskAccess)

        let fda = "artık taşınamadı: \(Trasher.fullDiskAccessMarker) (macOS uygulama verisi koruması; parola değil)"
        let mixed = TrashOutcome(report: TrashReport(
            dryRun: false, done: [makeDone(id: a.id, path: a.path, bytes: 300, action: "trashed")],
            refused: [.init(id: b.id, path: b.path, reason: fda), .init(id: c.id, path: c.path, reason: "kilitli")]), items: [a, b, c])
        #expect(mixed.failedCount == 2 && mixed.headline == "2 öğe taşınamadı" && mixed.needsFullDiskAccess)

        let none = TrashOutcome(report: TrashReport(dryRun: false, done: [],
                                                    refused: [.init(id: c.id, path: c.path, reason: "taşınamadı: iptal")]), items: [c])
        #expect(none.headline == "Öğe taşınamadı" && !none.needsFullDiskAccess)
        let none2 = TrashOutcome(report: TrashReport(dryRun: false, done: [], refused: [
            .init(id: b.id, path: b.path, reason: "x"), .init(id: c.id, path: c.path, reason: "y")]), items: [b, c])
        #expect(none2.headline == "2 öğenin hiçbiri taşınamadı")
    }

    @Test func progressState() {
        var p = ScanProgressState()
        p.apply(.init(scanner: "xcode", categories: [.xcode], event: .started, completed: 0, total: 2))
        #expect(p.status(.xcode) == .running)
        p.apply(.init(scanner: "xcode", categories: [.xcode], event: .finished(itemCount: 3, bytes: 9), completed: 1, total: 2))
        #expect(p.status(.xcode) == .done(itemCount: 3, bytes: 9))
        #expect(p.fraction == 0.5)
        p.finish(items: [item("a", cat: .caches, bytes: 5)])
        #expect(p.fraction == 1)
        #expect(p.status(.caches) == .done(itemCount: 1, bytes: 5))
    }

    @Test func formatting() {
        #expect(Fmt.dateText(.opened(days: 0)).value == "bugün")
        #expect(Fmt.dateText(.modified(days: 1)).value == "dün")
        #expect(Fmt.dateText(.modified(days: 90)).value == "3 ay önce")
        #expect(Fmt.dateText(.unknown).value == "bilinmiyor")
        #expect(Fmt.riskLabel(item("l", lock: "x")) == "Kullanımda")
    }
}
