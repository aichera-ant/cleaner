import Foundation
import Testing
@testable import CleanerKit

private func write(_ t: TempTree, _ rel: String, _ data: Data) throws -> URL {
    let u = t.home.appending(path: rel)
    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: u)
    return u
}

private func bytes(_ b: UInt8, _ n: Int) -> Data { Data(repeating: b, count: n) }

private func dupScanner() -> DuplicatesScanner {
    DuplicatesScanner(minBytes: 1024, prefixBytes: 64)
}

private func ctx(_ t: TempTree, git: FakeCommands = FakeCommands(), cloud: CloudGuard? = nil) -> ScanContext {
    .test(t, signals: .fake(commands: git), cloudGuard: cloud)
}

@Suite("Mükerrer dosyalar")
struct DuplicatesScannerTests {
    @Test("kademeli özet: aynı boyut + aynı önek ama farklı son, aynı grupta olmaz")
    func staged() async throws {
        let t = try TempTree()
        var a = bytes(1, 4000); var b = bytes(1, 4000)
        b[3999] = 2 // önek (64 bayt) aynı, tam içerik farklı
        _ = a.count
        a[0] = 1
        _ = try write(t, "Documents/a.bin", a)
        _ = try write(t, "Documents/b.bin", b)
        _ = try write(t, "Documents/c.bin", bytes(1, 4000)) // a ile aynı
        _ = try write(t, "Documents/d.bin", bytes(9, 4000)) // aynı boyut, farklı önek
        _ = try write(t, "Documents/e.bin", bytes(1, 3000)) // farklı boyut
        let items = try await dupScanner().scan(ctx(t))
        let names = Set(items.map(\.name))
        #expect(names == ["a.bin", "c.bin"])
        #expect(items.count == 2)
        #expect(items.filter { $0.risk == .info }.count == 1)
    }

    @Test("eşik altı dosyalar aranmaz")
    func minSize() async throws {
        let t = try TempTree()
        _ = try write(t, "Documents/a.bin", bytes(1, 500))
        _ = try write(t, "Documents/b.bin", bytes(1, 500))
        #expect(try await dupScanner().scan(ctx(t)).isEmpty)
    }

    @Test("tutulacak: Documents, İndirilenler'den önce; kopya yeşil ve seçili")
    func keeperPrefersDocuments() async throws {
        let t = try TempTree()
        _ = try write(t, "Downloads/rapor.pdf", bytes(5, 3000))
        _ = try write(t, "Documents/arsiv/belge-uzun-ad.pdf", bytes(5, 3000))
        let items = try await dupScanner().scan(ctx(t))
        #expect(items.count == 2)
        let keeper = try #require(items.first { $0.risk == .info })
        #expect(keeper.path.hasSuffix("Documents/arsiv/belge-uzun-ad.pdf"))
        #expect(keeper.method == .none && !keeper.isDefaultSelected && keeper.allocatedBytes == 0)
        let dup = try #require(items.first { $0.path.hasSuffix("Downloads/rapor.pdf") })
        #expect(dup.risk == .green && dup.isDefaultSelected)
        #expect(dup.note?.contains("Aynısı duruyor") == true)
        // Aynı grup anahtarı iki satırda da.
        let tag = try #require(keeper.note?.split(separator: " ").first)
        #expect(dup.note?.hasPrefix(String(tag)) == true)
    }

    @Test("aynı klasörde en kısa ad tutulur; eşitse en eski")
    func keeperShortestThenOldest() async throws {
        let t = try TempTree()
        let long = try write(t, "Downloads/odaglan 2 uzun ad.png", bytes(7, 3000))
        let short = try write(t, "Downloads/odaglan.png", bytes(7, 3000))
        let evrak = try write(t, "Downloads/evrak.png", bytes(7, 3000))
        // evrak ile odaglan'dan en eskisi evrak; ikisi de 10 değil -> evrak (6 harf) < odaglan (7 harf)
        _ = (long, short)
        let items = try await dupScanner().scan(ctx(t))
        #expect(items.count == 3)
        #expect(items.first { $0.risk == .info }?.path.hasSuffix("evrak.png") == true)
        // Eşit uzunlukta: en eski kalır.
        let t2 = try TempTree()
        let x = try write(t2, "Downloads/aaa.bin", bytes(3, 3000))
        let y = try write(t2, "Downloads/bbb.bin", bytes(3, 3000))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: y.path)
        _ = x
        let items2 = try await dupScanner().scan(ctx(t2))
        #expect(items2.first { $0.risk == .info }?.path.hasSuffix("bbb.bin") == true)
    }

    @Test("git'te takipli kopya kilitli; Müzik ve uygulama verisi sarı ve seçili değil")
    func lockedAndYellow() async throws {
        let t = try TempTree()
        _ = try write(t, "Documents/proje/.git/HEAD", Data("ref".utf8))
        _ = try write(t, "Documents/proje/img/foto.jpg", bytes(4, 3000))
        _ = try write(t, "Documents/proje/public/foto.jpg", bytes(4, 3000))
        _ = try write(t, "Music/arsiv/ses.wav", bytes(6, 3000))
        _ = try write(t, "Documents/ses.wav", bytes(6, 3000))
        _ = try write(t, ".claude/projects/x/ses.wav", bytes(6, 3000))
        let git = FakeCommands(result: CommandResult(exitCode: 0, stdout: "img/foto.jpg\0public/foto.jpg\0"))
        let items = try await dupScanner().scan(ctx(t, git: git))

        let foto = items.filter { $0.name == "foto.jpg" }
        #expect(foto.count == 2)
        let lockedFoto = foto.filter { $0.isLocked }
        #expect(lockedFoto.count == 1)
        #expect(lockedFoto[0].lockReason == "Git deposunda takipli")
        #expect(!lockedFoto[0].isDefaultSelected)

        let ses = items.filter { $0.name == "ses.wav" }
        #expect(ses.count == 3)
        #expect(ses.first { $0.risk == .info }?.path.hasSuffix("Documents/ses.wav") == true)
        let music = try #require(ses.first { $0.path.contains("/Music/") })
        let appData = try #require(ses.first { $0.path.contains("/.claude/") })
        #expect(music.risk == .yellow && !music.isDefaultSelected)
        #expect(appData.risk == .yellow && !appData.isDefaultSelected)
    }

    @Test("git doğrulanamazsa temkinli: kilitli")
    func gitFailureLocks() async throws {
        let t = try TempTree()
        _ = try write(t, "Documents/p/.git/HEAD", Data("ref".utf8))
        _ = try write(t, "Documents/p/a/x.bin", bytes(4, 3000))
        _ = try write(t, "Documents/p/b/x.bin", bytes(4, 3000))
        let git = FakeCommands(result: CommandResult(exitCode: 128, stdout: ""))
        let items = try await dupScanner().scan(ctx(t, git: git))
        #expect(items.filter(\.isLocked).count == 1)
        #expect(items.allSatisfy { !$0.isDefaultSelected })
    }

    @Test("yeniden oluşan klasörler, .git ve uygulama paketleri hariç")
    func excludedDirs() async throws {
        let t = try TempTree()
        for dir in ["node_modules/x", "DerivedData/y", "proje/.next/z", "Library/Caches/q", ".cache/c", "App.app/Contents",
                    "Library/Application Support/Code/User/workspaceStorage/a", "vendor/v", "build/b", "Pods/p", ".git/g"] {
            _ = try write(t, "Documents/\(dir)/f.bin", bytes(8, 3000))
        }
        _ = try write(t, "Library/Application Support/Code/User/workspaceStorage/a/f.bin", bytes(8, 3000))
        _ = try write(t, "Documents/gercek/f.bin", bytes(8, 3000))
        // Yalnız tek gerçek kopya var: grup oluşmaz.
        #expect(try await dupScanner().scan(ctx(t)).isEmpty)
        // İkinci gerçek kopya eklenince yalnız gerçekler çıkar.
        _ = try write(t, "Downloads/f.bin", bytes(8, 3000))
        let items = try await dupScanner().scan(ctx(t))
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.path.contains("/gercek/") || $0.path.contains("/Downloads/") })
    }

    @Test("bulut kökü altına hiç inilmez ve hiçbir dosya açılmaz")
    func cloudRootNeverRead() async throws {
        let t = try TempTree()
        _ = try write(t, "Library/Mobile Documents/com~apple~CloudDocs/a.bin", bytes(2, 3000))
        _ = try write(t, "Library/Mobile Documents/com~apple~CloudDocs/b.bin", bytes(2, 3000))
        _ = try write(t, "Library/CloudStorage/GoogleDrive-x/c.bin", bytes(2, 3000))
        // Bulut kökü, gezilen ağacın içinde (Documents altında) olacak şekilde sahte ana klasör.
        _ = try write(t, "Documents/fake/Library/Mobile Documents/d.bin", bytes(2, 3000))
        _ = try write(t, "Documents/fake/Library/Mobile Documents/e.bin", bytes(2, 3000))
        let opened = Counter()
        var context = ctx(t, cloud: CloudGuard(home: t.home.appending(path: "Documents/fake")))
        context.safeReader = SafeReader(cloudGuard: context.cloudGuard, willOpen: { opened.hit($0.path) })
        let items = try await dupScanner().scan(context)
        #expect(items.isEmpty)
        #expect(opened.n == 0)

        // Kök olarak doğrudan bulut klasörü verilse bile.
        var c2 = ctx(t)
        c2.roots = [t.home.appending(path: "Library/Mobile Documents")]
        let opened2 = Counter()
        c2.safeReader = SafeReader(cloudGuard: c2.cloudGuard, willOpen: { opened2.hit($0.path) })
        #expect(try await dupScanner().scan(c2).isEmpty)
        #expect(opened2.n == 0)
    }

    @Test("dataless dosya listelenmez, açılmaz")
    func datalessSkipped() async throws {
        let t = try TempTree()
        let a = try write(t, "Documents/a.bin", bytes(2, 3000))
        _ = try write(t, "Downloads/b.bin", bytes(2, 3000))
        let opened = Counter()
        var context = ctx(t, cloud: CloudGuard(home: t.home, probes: .init(
            isDataless: { $0.lastPathComponent == "a.bin" },
            isDownloadedCurrent: { _ in nil },
            isRegularFile: CloudGuard.Probes.live.isRegularFile
        )))
        context.safeReader = SafeReader(cloudGuard: context.cloudGuard, willOpen: { opened.hit($0.path) })
        _ = a
        #expect(try await dupScanner().scan(context).isEmpty)
        #expect(!opened.log.contains { $0.hasSuffix("a.bin") })
    }

    @Test("sabit bağlantı mükerrer sayılmaz")
    func hardLinksIgnored() async throws {
        let t = try TempTree()
        let a = try write(t, "Documents/a.bin", bytes(2, 3000))
        try FileManager.default.linkItem(at: a, to: t.home.appending(path: "Documents/b.bin"))
        #expect(try await dupScanner().scan(ctx(t)).isEmpty)
    }

    @Test("iptal edilince CancellationError")
    func cancellation() async throws {
        let t = try TempTree()
        for i in 0..<40 { _ = try write(t, "Documents/d\(i)/f.bin", bytes(2, 3000)) }
        let context = ctx(t)
        let task = Task { try await dupScanner().scan(context) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}

@Suite("Büyük ve eski dosyalar")
struct LargeOldScannerTests {
    func scanner() -> LargeOldScanner { LargeOldScanner(minFileBytes: 8_192, folderCandidateBytes: 100_000) }

    @Test("büyük dosya kırmızı ve seçili değil; İndirilenler'deki dmg sarı")
    func risks() async throws {
        let t = try TempTree()
        _ = try write(t, "Movies/film.mov", bytes(1, 20_000))
        _ = try write(t, "Downloads/kurulum.dmg", bytes(1, 20_000))
        _ = try write(t, "Downloads/kucuk.txt", bytes(1, 100))
        let items = try await scanner().scan(ctx(t))
        let film = try #require(items.first { $0.name == "film.mov" })
        #expect(film.risk == .red && !film.isDefaultSelected)
        let dmg = try #require(items.first { $0.name == "kurulum.dmg" })
        #expect(dmg.risk == .yellow && !dmg.isDefaultSelected)
        #expect(!items.contains { $0.name == "kucuk.txt" })
    }

    @Test("hariç tutulanlar: node_modules, .git, DerivedData, Library, bulut")
    func exclusions() async throws {
        let t = try TempTree()
        for p in ["proje/node_modules/a.bin", "proje/.git/b.bin", "proje/.next/c.bin", "Documents/DerivedData/d.bin",
                  "Library/Caches/e.bin", "Library/Mobile Documents/f.bin", "Library/CloudStorage/g/h.bin"] {
            _ = try write(t, p, bytes(1, 20_000))
        }
        _ = try write(t, "Library/Application Support/Foo/big.bin", bytes(1, 20_000))
        let items = try await scanner().scan(ctx(t))
        #expect(items.map(\.name).sorted() == ["big.bin"])
    }

    @Test("kurallarla örtüşen yol atlanır")
    func ruleCovered() async throws {
        let t = try TempTree()
        _ = try write(t, "Library/Application Support/Claude/vm_bundles/x.bin", bytes(1, 20_000))
        _ = try write(t, "Library/Application Support/Claude/baska.bin", bytes(1, 20_000))
        let rule = Rule(id: "r", path: "~/Library/Application Support/Claude/vm_bundles", category: .caches,
                        risk: .yellow, name: "vm", description: "d")
        let items = try await scanner().scan(.test(t, rules: [rule]))
        #expect(items.map(\.name) == ["baska.bin"])
    }

    @Test("seyrek dosya bilgi satırı; iki boyut notta")
    func sparse() async throws {
        let t = try TempTree()
        let u = t.home.appending(path: ".colima/default/datadisk")
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(u.path, O_CREAT | O_WRONLY, 0o644)
        #expect(fd >= 0)
        ftruncate(fd, 200_000_000)
        close(fd)
        let items = try await LargeOldScanner().scan(ctx(t))
        let item = try #require(items.first { $0.name == "datadisk" })
        #expect(item.risk == .info && item.method == .none && !item.isDefaultSelected)
        #expect(item.allocatedBytes < 1_000_000)
        #expect(item.note?.contains("görünen") == true && item.note?.contains("ayrılan") == true)
    }

    @Test("büyük klasör adayı tek satır, içindeki dosyalar ayrı satır olmaz")
    func folderCandidate() async throws {
        let t = try TempTree()
        for n in ["m1", "m2", "m3"] { _ = try write(t, "ai/mlmodel/\(n)/model.bin", bytes(1, 60_000)) }
        let items = try await scanner().scan(ctx(t))
        #expect(items.count == 1)
        #expect(items[0].name == "mlmodel" && items[0].risk == .red)
    }
}

@Suite("Klasörler")
struct FoldersScannerTests {
    @Test("boş ve yalnız .DS_Store klasörleri bulunur; git kökü, dolu klasör ve derin klasör hariç")
    func finds() async throws {
        let t = try TempTree()
        let root = try t.dir("projeler")
        try t.dir("bos", in: root)
        let ds = try t.dir("sadece-ds", in: root)
        try Data().write(to: ds.appending(path: ".DS_Store"))
        try t.file("dolu/a.txt", in: root)
        try t.dir("gitli/bos-ic", in: root)
        try t.dir("gitli/.git", in: root)
        try t.dir("a/b/cok-derin", in: root)
        try t.dir("a/bos-ikinci", in: root)
        var context = ScanContext.test(t)
        context.roots = [root]
        let items = try await FoldersScanner().scan(context)
        #expect(Set(items.map(\.name)) == ["bos", "sadece-ds", "bos-ikinci"])
        #expect(items.allSatisfy { $0.risk == .green && $0.isDefaultSelected })
    }

    @Test("korunan kök klasörler aday olmaz")
    func protectedRoots() async throws {
        let t = try TempTree()
        try t.dir("Desktop")
        try t.dir("Documents")
        var context = ScanContext.test(t)
        context.roots = [t.home]
        let items = try await FoldersScanner().scan(context)
        #expect(items.isEmpty)
    }
}
