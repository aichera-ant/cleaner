import CleanerKit
import Foundation
import Testing
@testable import CleanerAppCore

private func it(_ cat: ItemCategory, _ name: String, path: String, risk: Risk = .green, note: String? = nil,
                method: CleanMethod = .trash, days: Int? = nil, preselect: Bool? = nil) -> CleanItem {
    CleanItem(category: cat, name: name, path: path, allocatedBytes: 100, risk: risk,
              dateSignal: days.map { .modified(days: $0) } ?? .unknown, note: note, method: method, preselect: preselect)
}

@Suite struct ExplainerTests {
    @Test func derivedData() {
        let e = ItemExplainer.explain(it(.xcode, "DerivedData: App", path: "/x/DerivedData/App-abc"))
        #expect(e.what.contains("geçici dosyalar"))
        #expect(e.recovery == .regenerates)
    }

    @Test func worktreeDiffersFromDerivedData() {
        let a = ItemExplainer.explain(it(.xcode, "Worktree derlemesi: hepp-1d10a-den-rel", path: "/x/DerivedData/hepp"))
        #expect(a.what.contains("worktree"))
    }

    @Test func archiveIsNotRegenerable() {
        let e = ItemExplainer.explain(it(.xcode, "Arşiv: App", path: "/x/a.xcarchive", risk: .yellow))
        #expect(e.recovery == .trashRestorable)
        #expect(e.consequence.contains("dSYM"))
    }

    @Test func simulatorCommandIsPermanent() {
        let e = ItemExplainer.explain(it(.xcode, "Simülatör: iPhone 15 (iOS-17-2)", path: "/x/Devices/1", risk: .yellow, method: .command("xcrun simctl delete 1")))
        #expect(e.recovery == .permanent)
    }

    @Test func projectArtifacts() {
        let n = ItemExplainer.explain(it(.projectArtifacts, "node_modules (site)", path: "/p/site/node_modules"))
        #expect(n.recovery == .redownloads)
        #expect(n.what.contains("site"))
        let nx = ItemExplainer.explain(it(.projectArtifacts, ".next (site)", path: "/p/site/.next"))
        #expect(nx.recovery == .regenerates)
        let untracked = ItemExplainer.explain(it(.projectArtifacts, "dist (site)", path: "/p/site/dist", risk: .yellow, note: "Derleme çıktısı ama git yok sayma kuralı yok"))
        #expect(untracked.recovery == .trashRestorable)
    }

    @Test func recentProjectWarning() {
        let e = ItemExplainer.explain(it(.projectArtifacts, "node_modules (a)", path: "/p/a/node_modules", days: 12, preselect: false))
        #expect(e.heads.contains { $0.contains("Son 12 günde kullanıldı") })
        let g = ItemExplainer.explain(it(.projectArtifacts, "node_modules (a)", path: "/p/a/node_modules", note: "Git deposunda commit edilmemiş değişiklik var"))
        #expect(g.heads.contains { $0.contains("kaydedilmemiş") })
    }

    @Test func caches() {
        #expect(ItemExplainer.explain(it(.caches, "Homebrew önbelleği", path: "/Users/u/Library/Caches/Homebrew")).what.contains("Homebrew"))
        #expect(ItemExplainer.explain(it(.caches, "Chrome önbelleği", path: "/Users/u/Library/Caches/Google")).recovery == .regenerates)
        let npm = ItemExplainer.explain(it(.caches, "npm önbelleği", path: "/Users/u/.npm", method: .command("npm cache clean --force")))
        #expect(npm.recovery == .permanent)
        #expect(npm.what.contains("npm"))
    }

    @Test func docker() {
        #expect(ItemExplainer.explain(it(.docker, "İmaj: x", path: "docker://image/1")).recovery == .redownloads)
        #expect(ItemExplainer.explain(it(.docker, "Volume: db", path: "docker://volume/1", risk: .red, method: .command("docker volume rm db"))).recovery == .permanent)
        #expect(ItemExplainer.explain(it(.docker, "colima disk: a", path: "/x/a", risk: .info, method: .none)).recovery == .notRemovable)
    }

    @Test func oldVersions() {
        #expect(ItemExplainer.explain(it(.oldVersions, "Node v18.0.0 (nvm)", path: "/n", risk: .yellow)).what.contains("Node"))
        #expect(ItemExplainer.explain(it(.oldVersions, "Eklenti foo-1.0 (VS Code)", path: "/e")).what.contains("eklenti"))
    }

    @Test func largeOldAndDuplicatesNeverComeBack() {
        let big = ItemExplainer.explain(it(.largeOld, "film.mov", path: "/u/film.mov", risk: .red, note: "Kural dışı büyük dosya. Karar sizde."))
        #expect(big.recovery == .trashRestorable)
        #expect(big.consequence.contains("geri gelmez"))
        let dup = ItemExplainer.explain(it(.duplicates, "a.png", path: "/u/a.png"))
        #expect(dup.recovery == .trashRestorable)
        let inst = ItemExplainer.explain(it(.largeOld, "x.dmg", path: "/u/Downloads/x.dmg", risk: .yellow, note: "Kurulum/arşiv dosyası (İndirilenler)"))
        #expect(inst.recovery == .redownloads)
    }

    @Test func foldersAndApps() {
        #expect(ItemExplainer.explain(it(.folders, "bos", path: "/u/bos", note: "Boş klasör.")).recovery == .trashRestorable)
        #expect(ItemExplainer.explain(it(.apps, "Sketch", path: "/Applications/Sketch.app")).recovery == .trashRestorable)
    }

    @Test func unknownKindFallsBackToCategoryText() {
        let e = ItemExplainer.explain(it(.caches, "Bilinmeyen", path: "/u/Library/Caches/zzz"))
        #expect(e.what.contains("önbellek"))
        #expect(e.recovery == .regenerates)
        let x = ItemExplainer.explain(it(.xcode, "Başka", path: "/u/x"))
        #expect(!x.what.isEmpty)
    }

    @Test func summarySentences() {
        let regen = [it(.xcode, "DerivedData: A", path: "/a"), it(.caches, "Chrome önbelleği", path: "/b/Caches/Google")]
        #expect(ItemExplainer.summary(regen) == "Bunların hepsi kendiliğinden yeniden oluşur.")
        let mixed = regen + [it(.largeOld, "f", path: "/f", risk: .red)]
        #expect(ItemExplainer.summary(mixed).contains("1 tanesi"))
        let perm = [it(.docker, "Volume: v", path: "/v", method: .command("x"))]
        #expect(ItemExplainer.summary(perm).contains("kalıcı"))
    }

    @Test func zeroBytesFormat() {
        #expect(Fmt.bytes(0) == "0 bayt")
        #expect(!Fmt.bytes(512).contains("bytes"))
    }

    @Test func categoryIntrosExist() {
        for c in ItemCategory.allCases { #expect(!ItemExplainer.categoryIntro(c).isEmpty) }
    }

    @Test func heldBackGreens() {
        let a = it(.projectArtifacts, "a", path: "/a", preselect: false)
        let b = it(.projectArtifacts, "b", path: "/b")
        #expect(Summaries.heldBackGreens([a, b]).map(\.name) == ["a"])
    }
}

@Suite struct ItemSortTests {
    private func s(_ n: String, _ bytes: UInt64, days: Int? = nil, risk: Risk = .green) -> CleanItem {
        CleanItem(category: .caches, name: n, path: "/t/\(n)", allocatedBytes: bytes, risk: risk,
                  dateSignal: days.map { .modified(days: $0) } ?? .unknown)
    }

    @Test func sizeBothWaysTieByName() {
        let l = [s("b", 5), s("a", 5), s("c", 9)]
        #expect(ItemSort.sizeDescending.sorted(l).map(\.name) == ["c", "a", "b"])
        #expect(ItemSort.sizeAscending.sorted(l).map(\.name) == ["a", "b", "c"])
    }

    @Test func oldestFirstUnknownLast() {
        let l = [s("x", 1), s("new", 1, days: 2), s("old", 1, days: 300), s("y", 1)]
        #expect(ItemSort.oldestFirst.sorted(l).map(\.name) == ["old", "new", "x", "y"])
    }

    @Test func nameAndRisk() {
        let l = [s("b", 1, risk: .red), s("a", 1, risk: .yellow), s("c", 1, risk: .green)]
        #expect(ItemSort.nameAscending.sorted(l).map(\.name) == ["a", "b", "c"])
        #expect(ItemSort.risk.sorted(l).map(\.name) == ["c", "a", "b"])
    }
}
