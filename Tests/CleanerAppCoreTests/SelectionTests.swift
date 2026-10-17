import CleanerKit
import Foundation
import Testing
@testable import CleanerAppCore

@Suite struct SelectionTests {
    @Test func defaultsSelectOnlyGreenUnlocked() {
        let green = item("g")
        let yellow = item("y", risk: .yellow)
        let red = item("r", risk: .red)
        let locked = item("l", lock: "kullanımda")
        let noPre = item("p", preselect: false)
        let none = item("n", method: .none)
        let sel = SelectionState(defaultsFrom: [green, yellow, red, locked, noPre, none])
        #expect(sel.selectedIDs == [green.id])
    }

    @Test func redAndLockedNeverDefaultEvenIfFlagged() {
        let red = item("r", risk: .red, preselect: true)
        let locked = item("l", risk: .green, lock: "x")
        #expect(SelectionState(defaultsFrom: [red, locked]).selectedIDs.isEmpty)
    }

    @Test func lockedAndInfoCannotBeToggled() {
        let locked = item("l", lock: "kullanımda")
        let info = item("i", risk: .info)
        var sel = SelectionState()
        let r1 = sel.toggle(locked)
        let r2 = sel.toggle(info)
        #expect(!r1 && !r2)
        sel.set(locked, selected: true)
        #expect(sel.selectedIDs.isEmpty)
        #expect(!sel.isSelectable(locked))
    }

    @Test func toggleYellowWorks() {
        let y = item("y", risk: .yellow)
        var sel = SelectionState()
        let ok = sel.toggle(y)
        #expect(ok)
        #expect(sel.isSelected(y))
        sel.toggle(y)
        #expect(!sel.isSelected(y))
    }

    @Test func greensToggle() {
        let a = item("a"), b = item("b"), y = item("y", risk: .yellow), l = item("l", lock: "k")
        let all = [a, b, y, l]
        var sel = SelectionState()
        sel.toggleGreens(in: all)
        #expect(sel.selectedIDs == [a.id, b.id])
        #expect(sel.allGreensSelected(in: all))
        sel.toggleGreens(in: all)
        #expect(sel.selectedIDs.isEmpty)
    }

    @Test func selectedItemsFiltersStaleSelection() {
        let a = item("a")
        var sel = SelectionState(defaultsFrom: [a])
        // Tarama sonucu değişti: öğe artık kilitli.
        let lockedNow = a.locked("kullanımda")
        #expect(sel.selectedItems(in: [lockedNow]).isEmpty)
        sel.prune(to: [])
        #expect(sel.selectedIDs.isEmpty)
    }

    @Test func keeperSelectionIsKeptInStateAndBlocksSelection() {
        let k = item("k", cat: .duplicates, risk: .info, group: "g1", keeper: "k")
        let c1 = item("c1", cat: .duplicates, group: "g1", keeper: "k")
        let c2 = item("c2", cat: .duplicates, group: "g1", keeper: "k")
        var sel = SelectionState(defaultsFrom: [k, c1, c2])
        #expect(sel.selectedIDs == [c1.id, c2.id])
        #expect(sel.isKeeper(k))
        // Kullanıcı c1'i tutmak istiyor.
        sel.keep(c1)
        #expect(sel.keepers["g1"] == c1.path)
        #expect(sel.isKeeper(c1))
        #expect(!sel.isKeeper(k))
        #expect(!sel.isSelected(c1))
        let r = sel.toggle(c1)
        #expect(!r)
        #expect(sel.isSelected(c2))
        #expect(sel.selectedItems(in: [k, c1, c2]).map(\.id) == [c2.id])
    }

    @Test func keepOnLockedOrNonGroupIgnored() {
        var sel = SelectionState()
        sel.keep(item("x"))
        #expect(sel.keepers.isEmpty)
        sel.keep(item("l", cat: .duplicates, lock: "k", group: "g"))
        #expect(sel.keepers.isEmpty)
    }

    @Test func pruneDropsKeepersOfVanishedGroups() {
        var sel = SelectionState()
        let c = item("c", cat: .duplicates, group: "g1", keeper: "k")
        sel.keep(c)
        sel.prune(to: [item("z")])
        #expect(sel.keepers.isEmpty)
    }
}
