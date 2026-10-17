import CleanerKit
import Foundation
import Testing
@testable import CleanerAppCore

@Suite struct LeftoverTests {
    private func fixture() -> (app: CleanItem, exact: [CleanItem], named: CleanItem, all: [CleanItem]) {
        let app = appItem("Sketch", leftoverBytes: 300)
        let e1 = leftoverItem("e1", of: app, bytes: 200)
        let e2 = leftoverItem("e2", of: app, bytes: 100)
        let n = leftoverItem("n1", of: app, match: .name, bytes: 50)
        return (app, [e1, e2], n, [app, e1, e2, n])
    }

    private func state(_ items: [CleanItem]) -> SelectionState {
        var s = SelectionState()
        s.register(items)
        return s
    }

    @Test func defaultsDoNotSelectLeftoversOrApp() {
        let f = fixture()
        #expect(SelectionState(defaultsFrom: f.all).selectedIDs.isEmpty)
    }

    @Test func selectAppSelectsOnlyChosenLeftovers() {
        let f = fixture()
        var s = state(f.all)
        let ids = s.defaultLeftoverIDs(of: f.app)
        #expect(ids == Set(f.exact.map(\.id)))
        let ok1 = s.selectApp(f.app, leftoverIDs: ids)
        #expect(ok1)
        #expect(s.selectedIDs == Set([f.app.id] + f.exact.map(\.id)))
        #expect(!s.isSelected(f.named))
        // Başka seçimle yeniden: önceki artık seçimi yenisiyle değişir.
        let ok2 = s.selectApp(f.app, leftoverIDs: [f.named.id])
        #expect(ok2)
        #expect(s.selectedIDs == [f.app.id, f.named.id])
        let ok3 = s.selectApp(f.app, leftoverIDs: [])
        #expect(ok3)
        #expect(s.selectedIDs == [f.app.id])
    }

    @Test func deselectingAppClearsItsLeftovers() {
        let f = fixture()
        var s = state(f.all)
        s.selectApp(f.app, leftoverIDs: Set((f.exact + [f.named]).map(\.id)))
        s.set(f.app, selected: false)
        #expect(s.selectedIDs.isEmpty)
        s.selectApp(f.app, leftoverIDs: Set(f.exact.map(\.id)))
        s.toggle(f.app)
        #expect(s.selectedIDs.isEmpty)
        s.selectApp(f.app, leftoverIDs: Set(f.exact.map(\.id)))
        s.deselectAll(in: [f.app])
        #expect(s.selectedIDs.isEmpty)
    }

    @Test func leftoverCanBeSelectedAlone() {
        let f = fixture()
        var s = state(f.all)
        let ok4 = s.toggle(f.exact[0])
        #expect(ok4)
        #expect(s.isSelected(f.exact[0]) && !s.isSelected(f.app))
        let ok5 = s.toggle(f.named)
        #expect(ok5)
        #expect(s.selectedIDs == [f.exact[0].id, f.named.id])
        // Artığı kaldırmak uygulamaya dokunmaz.
        s.set(f.app, selected: true)
        s.set(f.exact[0], selected: false)
        #expect(s.isSelected(f.app))
    }

    @Test func lockedLeftoverAndLockedAppCannotBeSelected() {
        let app = appItem("Busy", risk: .locked, lock: "çalışıyor")
        let l = leftoverItem("l", of: app, lock: "uygulama kilitli: çalışıyor")
        var s = state([app, l])
        let n1 = s.selectApp(app, leftoverIDs: [l.id])
        #expect(!n1)
        let n2 = s.toggle(l)
        #expect(!n2)
        s.set(l, selected: true)
        #expect(s.selectedIDs.isEmpty)
        #expect(s.selectableLeftovers(of: app).isEmpty)

        let okApp = appItem("Ok")
        let lockedL = leftoverItem("ll", of: okApp, lock: "kilit")
        let freeL = leftoverItem("fl", of: okApp)
        var s2 = state([okApp, lockedL, freeL])
        s2.selectApp(okApp, leftoverIDs: [lockedL.id, freeL.id])
        #expect(s2.selectedIDs == [okApp.id, freeL.id])
    }

    @Test func infoLeftoverNotSelectable() {
        let app = appItem("A")
        var l = leftoverItem("i", of: app)
        l.risk = .info
        var s = state([app, l])
        let n3 = s.toggle(l)
        #expect(!n3)
    }

    @Test func selectAllTakesAppsAndExactLeftoversButNotNameMatches() {
        let f = fixture()
        var s = state(f.all)
        s.selectAll(in: f.all)
        #expect(s.selectedIDs == Set([f.app.id] + f.exact.map(\.id)))
        #expect(!s.isSelected(f.named))
    }

    @Test func selectAllOrderIndependentAndSkipsLeftoversOfUnselectableApp() {
        let f = fixture()
        var s = state(f.all.reversed())
        s.selectAll(in: f.all.reversed())
        #expect(s.selectedIDs == Set([f.app.id] + f.exact.map(\.id)))

        let busy = appItem("Busy", risk: .locked, lock: "çalışıyor")
        let free = appItem("Free")
        // Uygulama seçilemiyorsa (kilitli ya da bilgi) artığı da toplu seçimde gelmez.
        let info = appItem("Info", risk: .info)
        let l = leftoverItem("l", of: info)
        var s2 = state([busy, free, info, l])
        s2.selectAll(in: [busy, free, info, l])
        #expect(s2.selectedIDs == [free.id])
    }

    @Test func selectAllPreviewMatchesSelectAll() {
        let f = fixture()
        let s = state(f.all)
        #expect(s.selectAllPreview(in: f.all).added == 3)
    }

    @Test func orphanLeftoverNotSelectable() {
        let app = appItem("A")
        let orphan = leftoverItem("o", of: nil, parentID: "ffffffffffff")
        var s = state([app, orphan])
        #expect(s.isOrphan(orphan))
        let n4 = s.toggle(orphan)
        #expect(!n4)
        s.selectAll(in: [app, orphan])
        #expect(s.selectedIDs == [app.id])
    }

    @Test func greensToggleIgnoresLeftovers() {
        let f = fixture()
        var s = state(f.all)
        s.toggleGreens(in: f.all)
        #expect(s.selectedIDs.isEmpty)
    }

    @Test func pruneKeepsMapping() {
        let f = fixture()
        var s = state(f.all)
        s.selectApp(f.app, leftoverIDs: Set(f.exact.map(\.id)))
        s.prune(to: [f.app, f.exact[0]])
        #expect(s.selectedIDs == [f.app.id, f.exact[0].id])
        s.set(f.app, selected: false)
        #expect(s.selectedIDs.isEmpty)
    }

    @Test func layoutGroupsByAppAndOrphans() {
        let f = fixture()
        let small = appItem("Zed", bytes: 10)
        let orphan = leftoverItem("o", of: nil, bytes: 5, parentID: "ffffffffffff")
        let layout = Summaries.appsLayout(f.all + [small, orphan], sort: .sizeDescending)
        #expect(layout.groups.map(\.app.name) == ["Sketch", "Zed"])
        #expect(layout.groups[0].leftovers.map(\.name) == ["e1", "e2", "n1"])
        #expect(layout.groups[0].leftoverBytes == 350 && layout.groups[0].exactCount == 2)
        #expect(layout.orphans.map(\.name) == ["o"])
        let byName = Summaries.appsLayout(f.all + [small], sort: .nameAscending)
        #expect(byName.groups.map(\.app.name) == ["Sketch", "Zed"])
    }

    @Test func appsSummaryCountsAppsAndLeftoversSeparately() {
        let f = fixture()
        let s = Summaries.appsSummary(f.all)
        #expect(s.appCount == 1 && s.leftoverCount == 3)
        #expect(s.appBytes == 1000 && s.leftoverBytes == 350 && s.totalBytes == 1350)
    }

    @Test func planGroupsLeftoversUnderApps() {
        let f = fixture()
        let other = appItem("Other", bytes: 10)
        let strayParent = appItem("Stay")
        let stray = leftoverItem("stray", of: strayParent)
        let plan = TrashPlan(selected: [f.app, f.exact[0], other, stray])
        #expect(plan.appGroups.count == 3)
        #expect(plan.appGroups[0].app?.id == f.app.id && plan.appGroups[0].leftovers.map(\.id) == [f.exact[0].id])
        #expect(plan.appGroups[1].app?.id == other.id && plan.appGroups[1].leftovers.isEmpty)
        #expect(plan.appGroups[2].app == nil && plan.appGroups[2].leftovers.map(\.id) == [stray.id])
        #expect(plan.itemCount == 4)
    }

    @Test func outcomeGroupsSkippedLeftoversUnderApp() throws {
        let f = fixture()
        let skip = TrashOutcome.appFailedSkipReason
        let report = TrashReport(dryRun: false, done: [], refused: [
            .init(id: f.app.id, path: f.app.path, reason: "izin yok"),
            .init(id: f.exact[0].id, path: f.exact[0].path, reason: skip),
            .init(id: f.exact[1].id, path: f.exact[1].path, reason: skip),
        ])
        let o = TrashOutcome(report: report, items: f.all)
        #expect(o.refusedOther.map(\.id) == [f.app.id])
        #expect(o.appSkipGroups.count == 1)
        #expect(o.appSkipGroups[0].appName == "Sketch" && o.appSkipGroups[0].lines.count == 2)
    }

    @Test func explainerLeftoverKindsAndNameWarning() {
        let app = appItem("Sketch")
        func ex(_ path: String, _ m: LeftoverMatch = .bundleID) -> ItemExplanation {
            ItemExplainer.explain(leftoverItem("x", of: app, match: m, path: path))
        }
        let h = NSHomeDirectory()
        #expect(ex("\(h)/Library/Application Support/Sketch").what.hasPrefix("Uygulamanın ayarları ve verileri"))
        #expect(ex("\(h)/Library/Caches/com.x").recovery == .regenerates)
        #expect(ex("\(h)/Library/Preferences/com.x.plist").what.contains("ayar"))
        #expect(ex("\(h)/Library/Logs/Sketch").what.contains("kayıt"))
        #expect(ex("\(h)/Library/Containers/com.x").what.contains("kutusu"))
        #expect(ex("\(h)/Library/Group Containers/ABC.com.x").what.contains("ortak"))
        #expect(ex("\(h)/Library/Saved Application State/com.x.savedState").what.contains("pencere"))
        #expect(ex("\(h)/Library/HTTPStorages/com.x").what.contains("oturum"))
        #expect(ex("\(h)/Library/WebKit/com.x").what.contains("web"))
        #expect(ex("\(h)/.sketch").what.contains(".sketch"))
        #expect(ex("\(h)/Library/Caches/x").heads.isEmpty)
        #expect(ex("\(h)/Library/Caches/x", .name).heads.contains { $0.contains("Adı benziyor") })
        #expect(ex("\(h)/Library/Application Support/Sketch").consequence.contains("sıfırdan"))
    }
}
