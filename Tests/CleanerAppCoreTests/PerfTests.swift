import CleanerKit
import Foundation
import Testing
@testable import CleanerAppCore

/// Zamanlama ölçümü (sahte veri): sayfa açılışında hesap tarafı. Süreleri yazdırır; eşikler gevşektir.
@Suite struct PerfTests {
    static func dupItems(groups: Int = 300, per: Int = 3) -> [CleanItem] {
        var out: [CleanItem] = []
        for g in 0..<groups {
            for m in 0..<per {
                out.append(item("dup\(g)-\(m)", cat: .duplicates, bytes: UInt64(1000 + g), risk: m == 0 ? .green : .yellow,
                                group: "g\(g)", keeper: "dup\(g)-0"))
            }
        }
        return out
    }

    static func catItems(_ n: Int = 1000) -> [CleanItem] {
        (0..<n).map { item("c\($0)", cat: .caches, bytes: UInt64($0 * 7 % 997), risk: [.green, .yellow, .red][$0 % 3]) }
    }

    static func ms(_ body: () -> Void) -> Double {
        let c = ContinuousClock()
        let d = c.measure(body)
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// Eski görünümün her çizimde yaptığı iş (hepsi görünür kabul edilir: tembel olmayan yığın).
    @Test func baselineRenderCompute() {
        let d = Self.dupItems()
        var sel = SelectionState(defaultsFrom: d)
        let t1 = Self.ms {
            let groups = Summaries.duplicateGroups(d)
            _ = sel.selectedItems(in: d).filter { $0.category == .duplicates }
            for g in groups { for m in g.members { _ = sel.isKeeper(m); _ = sel.isSelected(m); _ = sel.effective(m); _ = sel.isSelectable(m) } }
        }
        let c = Self.catItems()
        let t2 = Self.ms {
            let its = ItemSort.sizeDescending.sorted(c.filter { $0.category == .caches })
            _ = its.filter { sel.isSelected($0) }.count
            _ = sel.allGreensSelected(in: its)
            for i in its { _ = ItemExplainer.explain(i); _ = sel.isSelectable(i); _ = sel.isSelected(i) }
        }
        print("PERF baseline: mükerrer sayfa çizimi \(t1) ms; kategori (1000) çizimi \(t2) ms")
        _ = sel.toggle(d[1])
    }

    /// Yeni yol: önbellekli erişim + yalnız görünen (~20) satırın hesabı + toplu seçim.
    @MainActor @Test func afterRenderCompute() async {
        let d = Self.dupItems()
        let c = Self.catItems()
        let model = AppModel(scanService: FakeScan(ScanSnapshot(items: d + c, scannedAt: Date())), trashService: FakeTrash(),
                             diskProvider: { nil })
        await model.startScan()
        var groups: [DuplicateGroup] = []
        let first = Self.ms { groups = model.duplicateGroups; _ = model.sortedItems(in: .caches, by: .sizeDescending) }
        let t1 = Self.ms {
            _ = model.duplicateGroups
            for g in groups.prefix(8) { for m in g.members { _ = model.selection.isKeeper(m); _ = model.selection.isSelected(m); _ = model.selection.effective(m) } }
        }
        let t2 = Self.ms {
            let its = model.sortedItems(in: .caches, by: .sizeDescending)
            for i in its.prefix(20) { _ = model.explanation(for: i); _ = model.selection.isSelectable(i) }
        }
        let all = groups.flatMap(\.members)
        let t3 = Self.ms { _ = model.selection.selectAllPreview(in: all); model.selection.selectAll(in: all) }
        print("PERF after: ilk hesap \(first) ms; mükerrer sayfa yeniden çizim (önbellekli, 8 grup görünür) \(t1) ms; kategori çizim (20 satır) \(t2) ms; 900 öğede tümünü seç+önizleme \(t3) ms")
    }
}
