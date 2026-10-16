import Darwin
import Foundation
import Testing
@testable import CleanerKit

@Suite("Boyut ölçümü")
struct SizeMeterTests {
    @Test("seyrek dosya ayrılan boyutla ölçülür")
    func sparseFile() async throws {
        let t = try TempTree()
        let f = t.home.appending(path: "datadisk")
        let fd = open(f.path, O_CREAT | O_WRONLY, 0o644)
        #expect(fd >= 0)
        #expect(ftruncate(fd, 10 * 1024 * 1024 * 1024) == 0) // 10 GB görünen
        _ = "x".withCString { write(fd, $0, 1) }
        close(fd)
        let m = try await SizeMeter().measure(f)
        #expect(m.allocatedBytes < 1024 * 1024, "seyrek dosya \(m.allocatedBytes) bayt ölçüldü")
        let dirM = try await SizeMeter().measure(t.home)
        #expect(dirM.allocatedBytes < 1024 * 1024)
    }

    @Test("klasör toplamı ve dosya sayısı")
    func directoryTotal() async throws {
        let t = try TempTree()
        for i in 0..<20 { try t.file("a/b\(i % 3)/f\(i).bin", bytes: 100_000) }
        let m = try await SizeMeter(maxConcurrency: 3).measure(t.home.appending(path: "a"))
        #expect(m.fileCount == 20)
        #expect(m.allocatedBytes >= 2_000_000)
        #expect(m.newestModification != nil)
    }

    @Test("sembolik bağlantı izlenmez")
    func symlinksNotFollowed() async throws {
        let t = try TempTree()
        let big = try t.dir("big", in: t.root)
        try t.file("payload.bin", bytes: 5_000_000, in: big)
        let scanned = try t.dir("scanned")
        try FileManager.default.createSymbolicLink(at: scanned.appending(path: "link"), withDestinationURL: big)
        try FileManager.default.createSymbolicLink(
            at: scanned.appending(path: "filelink"), withDestinationURL: big.appending(path: "payload.bin"))
        let m = try await SizeMeter().measure(scanned)
        #expect(m.allocatedBytes < 100_000, "bağlantı izlenmiş: \(m.allocatedBytes)")
        let rootLink = try await SizeMeter().measure(scanned.appending(path: "link"))
        #expect(rootLink.allocatedBytes < 100_000)
    }

    @Test("izin hatası çökertmez")
    func permissionDenied() async throws {
        let t = try TempTree()
        try t.file("ok/a.bin", bytes: 50_000)
        let locked = try t.dir("ok/locked")
        try t.file("secret.bin", bytes: 50_000, in: locked)
        chmod(locked.path, 0)
        defer { chmod(locked.path, 0o755) }
        let m = try await SizeMeter().measure(t.home.appending(path: "ok"))
        #expect(m.skippedCount >= 1)
        #expect(m.allocatedBytes >= 50_000)
    }

    @Test("iptal edilebilir")
    func cancellable() async throws {
        let t = try TempTree()
        for i in 0..<50 { try t.file("d\(i)/f.bin", bytes: 10) }
        let task = Task { try await SizeMeter().measure(t.home) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("çoklu ölçüm girdi sırasını korur")
    func multiple() async throws {
        let t = try TempTree()
        let a = try t.file("a.bin", bytes: 1_000_000)
        let b = try t.file("b.bin", bytes: 10)
        let r = try await SizeMeter().measure([a, b, t.home.appending(path: "yok")])
        #expect(r[0].allocatedBytes > r[1].allocatedBytes)
        #expect(r[2].skippedCount == 1)
    }
}

@Suite("Kural motoru")
struct RuleTests {
    @Test("paketteki rules.json yüklenir ve geçerli")
    func bundled() throws {
        let set = try RuleSet.loadBundled()
        #expect(set.rules.count >= 11)
        let npm = try #require(set.rules.first { $0.id == "npm-cache" })
        #expect(npm.method == .command("npm cache clean --force"))
        #expect(set.rules.first { $0.id == "playwright-browsers" }?.risk == .yellow)
        #expect(set.rules.first { $0.id == "claude-vm-bundles" }?.risk == .yellow)
        #expect(set.rules.first { $0.id == "pnpm-store" }?.method == .command("pnpm store prune"))
        // Hiçbir kural korunan bir yolu hedeflemez.
        let t = try TempTree()
        let policy = PathPolicy(home: t.home)
        for r in set.rules where !r.path.contains("*") {
            #expect(policy.protectionReason(for: PathExpander.expand(r.path, home: t.home)) == nil, "\(r.id)")
        }
    }

    @Test("geçersiz kural reddedilir")
    func invalid() throws {
        let bad = #"{"version":1,"rules":[{"id":"x","path":"~/a/../.ssh","category":"caches","risk":"green","name":"x","description":"x"}]}"#
        #expect(throws: (any Error).self) { try RuleSet.decode(Data(bad.utf8)) }
        let abs = #"{"version":1,"rules":[{"id":"x","path":"/etc","category":"caches","risk":"green","name":"x","description":"x"}]}"#
        #expect(throws: (any Error).self) { try RuleSet.decode(Data(abs.utf8)) }
    }

    @Test("~ açılımı ve * glob")
    func glob() throws {
        let t = try TempTree()
        try t.dir("Library/Caches/com.a.one")
        try t.dir("Library/Caches/com.a.two")
        try t.dir("Library/Caches/org.b")
        try t.dir("Library/Caches/.com.a.hidden")
        let found = PathExpander.glob("~/Library/Caches/com.a.*", home: t.home).map(\.lastPathComponent)
        #expect(found == ["com.a.one", "com.a.two"])
        #expect(PathExpander.glob("~/Library/Caches/yok", home: t.home).isEmpty)
        #expect(PathExpander.glob("~/*/Caches/org.b", home: t.home).count == 1)
    }

    @Test("kural tarayıcı eşleşir, yöntem/risk/kilit uygulanır")
    func ruleScanner() async throws {
        let t = try TempTree()
        try t.file(".npm/_cacache/x.bin", bytes: 200_000)
        try t.file("Library/Caches/ms-playwright/chromium/a.bin", bytes: 300_000)
        try t.file("Library/Application Support/Claude/vm_bundles/b.bin", bytes: 100_000)
        let rules = try RuleSet.loadBundled().rules
        let later = Date().addingTimeInterval(3 * 3600)

        // 3 saat sonra, Claude çalışıyor.
        let ctx = ScanContext.test(t, now: later, signals: .fake(processes: FakeProcesses(names: ["Claude"])), rules: rules)
        let items = try await RuleBasedScanner().scan(ctx)
        let npm = try #require(items.first { $0.path.hasSuffix("/.npm") })
        #expect(npm.method == .command("npm cache clean --force"))
        #expect(npm.risk == .green && npm.isDefaultSelected)
        #expect(npm.allocatedBytes >= 200_000)
        #expect(npm.dateSignal == .modified(days: 0))
        let pw = try #require(items.first { $0.path.hasSuffix("ms-playwright") })
        #expect(pw.risk == .yellow && !pw.isDefaultSelected)
        let vm = try #require(items.first { $0.path.hasSuffix("vm_bundles") })
        #expect(vm.isLocked && vm.lockReason == "Claude çalışıyor")
        #expect(items.count == 3)

        // Şimdi: hepsi son 1 saatte değişti → kilitli. `claude` (CLI) Claude masaüstü değildir.
        let now = ScanContext.test(t, signals: .fake(processes: FakeProcesses(names: ["claude"])), rules: rules)
        let fresh = try await RuleBasedScanner().scan(now)
        #expect(fresh.allSatisfy { $0.isLocked && $0.lockReason == "son 1 saatte değişti" })
    }

    @Test("korunan yolu hedefleyen kural öğe üretmez")
    func protectedRule() async throws {
        let t = try TempTree()
        try t.file(".ssh/id_ed25519")
        try t.file("Library/Keychains/login.keychain-db")
        let rules = [
            Rule(id: "ssh", path: "~/.ssh", category: .caches, risk: .green, name: "x", description: "x"),
            Rule(id: "kc", path: "~/Library/Keychains/*", category: .caches, risk: .green, name: "x", description: "x"),
            Rule(id: "home", path: "~/*", category: .caches, risk: .green, name: "x", description: "x"),
        ]
        let items = try await RuleBasedScanner(rules: rules).scan(.test(t))
        #expect(items.allSatisfy { !$0.path.contains(".ssh") && !$0.path.contains("Keychains") && !$0.path.hasSuffix("/Library") })
    }
}

@Suite("Model")
struct ModelTests {
    @Test("id yol tabanlı ve stabil; JSON gidiş-dönüş")
    func idAndCodable() throws {
        let a = CleanItem(category: .caches, name: "a", path: "/Users/x/Library/Caches/A/", allocatedBytes: 5, risk: .green)
        let b = CleanItem(category: .xcode, name: "b", path: "/Users/x/Library/Caches/A", allocatedBytes: 9, risk: .red)
        #expect(a.id == b.id)
        #expect(a.id.count == 12)
        #expect(a.id != CleanItem.makeID(path: "/Users/x/Library/Caches/B"))
        let c = CleanItem(category: .caches, name: "c", path: "/tmp/c", allocatedBytes: 1, risk: .green,
                          dateSignal: .opened(days: 3), lockReason: "çalışıyor", note: "n", method: .command("echo"))
        #expect(c.risk == .locked && !c.isDefaultSelected)
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(CleanItem.self, from: data) == c)
        #expect(String(decoding: try JSONEncoder().encode(CleanMethod.trash), as: UTF8.self).contains("trash"))
    }
}

struct FakeCleaner: Cleaner {
    var id: String
    var categories: Set<CleanerKit.Category>
    var items: [CleanItem] = []
    var error: (any Error & Sendable)? = nil
    func scan(_ context: ScanContext) async throws -> [CleanItem] {
        if let error { throw error }
        return items
    }
}

struct Boom: Error {}

@Suite("Tarama motoru")
struct ScanEngineTests {
    @Test("korunan öğeleri atar, tekrarları birleştirir, süzer, sıralar, hatayı raporlar")
    func engine() async throws {
        let t = try TempTree()
        let h = t.home.path
        var r = CleanerRegistry()
        r.register(FakeCleaner(id: "a", categories: [.caches], items: [
            CleanItem(category: .caches, name: "küçük", path: h + "/Library/Caches/x", allocatedBytes: 10, risk: .green),
            CleanItem(category: .caches, name: "ssh", path: h + "/.ssh", allocatedBytes: 999, risk: .green),
            CleanItem(category: .caches, name: "home", path: h, allocatedBytes: 999, risk: .green),
        ]))
        r.register(FakeCleaner(id: "b", categories: [.xcode], items: [
            CleanItem(category: .xcode, name: "büyük", path: h + "/Library/Developer/Xcode/DerivedData/P", allocatedBytes: 100, risk: .green),
            CleanItem(category: .caches, name: "tekrar", path: h + "/Library/Caches/x", allocatedBytes: 10, risk: .green),
        ]))
        r.register(FakeCleaner(id: "c", categories: [.docker], error: Boom()))
        let report = try await ScanEngine(registry: r).scan(.test(t))
        #expect(report.items.map(\.name) == ["büyük", "küçük"])
        #expect(report.dropped.count == 2)
        #expect(report.errors.map(\.scanner) == ["c"])
        // Varsayılan: kategori süzgeci verilse de bütün tarayıcılar çalışır (kilit hesabı tam).
        let onlyX = try await ScanEngine(registry: r).scan(.test(t), categories: [.xcode])
        #expect(onlyX.items.map(\.name) == ["büyük"])
        #expect(onlyX.errors.map(\.scanner) == ["c"])
        // Hızlı görüntüleme: yalnız ilgili tarayıcılar.
        let fast = try await ScanEngine(registry: r).scan(.test(t), categories: [.xcode], fullLockCheck: false)
        #expect(fast.items.map(\.name) == ["büyük"])
        #expect(fast.errors.isEmpty)
    }

    @Test("varsayılan kayıt kural tarayıcısını içerir")
    func defaultRegistry() {
        #expect(CleanerRegistry.makeDefault().cleaners.contains { $0.id == "rules" })
    }
}
