import CleanerKit
import Foundation
import Testing
@testable import CleanerAppCore

@Suite struct BulkSelectTests {
    @Test func selectAllSkipsLockedInfoNoneAndIncludesNeedsAuthorization() {
        let g = item("g"), y = item("y", risk: .yellow), r = item("r", risk: .red)
        let app = item("app", cat: .apps, risk: .yellow, auth: true)
        let locked = item("l", lock: "kullanımda"), info = item("i", risk: .info), none = item("n", method: .none)
        var sel = SelectionState()
        sel.selectAll(in: [g, y, r, app, locked, info, none])
        #expect(sel.selectedIDs == [g.id, y.id, r.id, app.id])
    }

    @Test func selectAllWithoutRedSkipsRed() {
        let g = item("g"), r = item("r", risk: .red)
        var sel = SelectionState()
        sel.selectAll(in: [g, r], includeRed: false)
        #expect(sel.selectedIDs == [g.id])
    }

    @Test func categoryBoundary() {
        let a = item("a"), b = item("b", cat: .xcode)
        var sel = SelectionState()
        sel.selectAll(in: [a])
        #expect(sel.selectedIDs == [a.id])
        sel.selectAll(in: [b])
        sel.deselectAll(in: [a])
        #expect(sel.selectedIDs == [b.id])
    }

    @Test func previewCountsRedAndDoesNotMutate() {
        let g = item("g"), r1 = item("r1", risk: .red), r2 = item("r2", risk: .red), l = item("l", lock: "x")
        var sel = SelectionState()
        sel.set(r2, selected: true)
        let p = sel.selectAllPreview(in: [g, r1, r2, l])
        #expect(p.added == 2 && p.red == 1)
        #expect(sel.selectedIDs == [r2.id])
    }

    @Test func duplicatesKeepOneAndNeverKeeperOrLocked() {
        let k = item("k", cat: .duplicates, group: "G", keeper: "k")
        let a = item("a", cat: .duplicates, group: "G", keeper: "k")
        let b = item("b", cat: .duplicates, group: "G", keeper: "k")
        let l = item("l", cat: .duplicates, lock: "kullanımda", group: "G", keeper: "k")
        var sel = SelectionState(defaultsFrom: [k, a, b, l])
        sel.deselectAll(in: [k, a, b, l])
        sel.selectExtraCopies(of: [k, a, b, l])
        #expect(sel.selectedIDs == [a.id, b.id])
        // Anahtar kopya kendisi tutulan: hepsi kilitliyse hiçbiri seçilmez.
        var s2 = SelectionState(defaultsFrom: [k, l])
        s2.clear()
        s2.selectExtraCopies(of: [k, l])
        #expect(s2.selectedIDs.isEmpty)
    }

    @Test func userKeeperChoiceRespectedAndOneRemains() {
        let k = item("k", cat: .duplicates, group: "G", keeper: "k", ifNotKeptRisk: .yellow)
        let a = item("a", cat: .duplicates, risk: .yellow, group: "G", keeper: "k")
        var sel = SelectionState(defaultsFrom: [k, a])
        sel.keep(a)
        sel.selectAll(in: [k, a])
        #expect(sel.selectedIDs == [k.id])
        // Tutulacak "a" asla seçilmez, "k" seçili: "a" kalır.
        #expect(!sel.isSelected(a))
    }

    @Test func groupsAreIndependentAndRedExcludedKeepsOneAnyway() {
        var all: [CleanItem] = []
        for g in 0..<3 {
            all.append(item("k\(g)", cat: .duplicates, group: "G\(g)", keeper: "k\(g)"))
            all.append(item("x\(g)", cat: .duplicates, risk: .red, group: "G\(g)", keeper: "k\(g)"))
            all.append(item("y\(g)", cat: .duplicates, risk: .yellow, group: "G\(g)", keeper: "k\(g)"))
        }
        var sel = SelectionState(defaultsFrom: all)
        sel.clear()
        let p = sel.selectAllPreview(in: all)
        #expect(p.added == 6 && p.red == 3)
        sel.selectAll(in: all, includeRed: false)
        #expect(sel.selectedIDs.count == 3)
        for g in 0..<3 { #expect(!sel.selectedIDs.contains(all[g * 3].id)) }
    }
}
