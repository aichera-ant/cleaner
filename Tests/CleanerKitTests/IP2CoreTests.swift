import Darwin
import Foundation
import Testing
@testable import CleanerKit

// İP2 çekirdek: tarama ilerlemesi, ItemCategory, yetkili taşıma (Uygulama Yönetimi / root), "Bunu tut",
// mükerrer son kopya uç durumu. Yalnız geçici klasör; yetkili taşıyıcı sahtedir (gerçek NSWorkspace çağrılmaz).

/// Geçici "FakeTrash"e taşıyan ve çağrıları sayan sahte taşıyıcı.
struct FakeRecycler: Recycling {
    let bin: URL
    let counter: Counter

    init(_ t: TempTree, name: String, counter: Counter) throws {
        bin = try t.dir(name, in: t.root)
        self.counter = counter
    }

    func recycle(_ url: URL) async throws -> URL? {
        counter.hit(url.path)
        let dest = bin.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }
}

/// Paket adına göre yazma gözlemi (geri kalanı yazılabilir).
private func probe(_ byName: [String: AppWriteFacts]) -> AppWriteProbe {
    AppWriteProbe { bundle, _ in
        byName[(bundle as NSString).lastPathComponent]
            ?? AppWriteFacts(parentWritable: true, bundleErrno: nil, ownerUID: getuid())
    }
}

private let appManaged = AppWriteFacts(parentWritable: true, bundleErrno: EPERM, ownerUID: getuid())
private let rootOwned = AppWriteFacts(parentWritable: true, bundleErrno: EACCES, ownerUID: 0)
private let otherUser = AppWriteFacts(parentWritable: true, bundleErrno: EACCES, ownerUID: getuid() &+ 1)

// MARK: 1-2. İlerleme ve takma ad

private struct StubCleaner: Cleaner {
    var id: String
    var categories: Set<CleanerKit.Category>
    var phase: Int = 0
    var items: [CleanItem] = []
    var fails = false

    struct Boom: Error, CustomStringConvertible { var description: String { "patladı" } }

    func scan(_ context: ScanContext) async throws -> [CleanItem] {
        if fails { throw Boom() }
        return items
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ScanProgress] = []
    var events: [ScanProgress] { lock.withLock { _events } }
    func add(_ e: ScanProgress) { lock.withLock { _events.append(e) } }
}

@Suite("Tarama ilerlemesi")
struct ScanProgressTests {
    @Test("her tarayıcı başında ve sonunda (faz 2 dahil) olay; hata failed olarak gelir")
    func events() async throws {
        let t = try TempTree()
        let f1 = try t.file("a/x.bin", bytes: 10)
        let f2 = try t.file("b/y.bin", bytes: 10)
        var r = CleanerRegistry()
        r.register(StubCleaner(id: "one", categories: [.caches, .xcode], items: [
            CleanItem(category: .caches, name: "x", path: f1.path, allocatedBytes: 100, risk: .green),
            CleanItem(category: .xcode, name: "y", path: f2.path, allocatedBytes: 50, risk: .green),
        ]))
        r.register(StubCleaner(id: "bad", categories: [.docker], fails: true))
        r.register(StubCleaner(id: "late", categories: [.largeOld], phase: 1))
        let log = EventLog()
        let report = try await ScanEngine(registry: r).scan(.test(t)) { log.add($0) }
        #expect(report.items.count == 2 && report.errors.count == 1)

        let ev = log.events
        #expect(ev.count == 6)
        #expect(ev.allSatisfy { $0.total == 3 })
        for id in ["one", "bad", "late"] {
            let mine = ev.filter { $0.scanner == id }
            #expect(mine.count == 2 && mine[0].event == .started, "\(id): \(mine)")
        }
        let one = ev.filter { $0.scanner == "one" }
        #expect(one[1].event == .finished(itemCount: 2, bytes: 150))
        #expect(one[0].categories == [.xcode, .caches]) // Category.allCases sırası
        #expect(ev.first { $0.scanner == "bad" && $0.event != .started }?.event == .failed("patladı"))
        // Faz 2 tarayıcısı ilk fazın ikisi bittikten sonra başlar.
        let lateStart = try #require(ev.first { $0.scanner == "late" })
        #expect(lateStart.completed == 2)
        #expect(ev.last?.completed == 3 && ev.last?.scanner == "late")
        #expect(ev.filter { $0.event != .started }.map(\.completed).sorted() == [1, 2, 3])
    }

    @Test("süzülen tarayıcılar sayılmaz; ilerleme verilmezse davranış aynı")
    func filtered() async throws {
        let t = try TempTree()
        var r = CleanerRegistry()
        r.register(StubCleaner(id: "a", categories: [.caches]))
        r.register(StubCleaner(id: "b", categories: [.docker]))
        let log = EventLog()
        _ = try await ScanEngine(registry: r).scan(.test(t), categories: [.docker], fullLockCheck: false) { log.add($0) }
        #expect(log.events.map(\.scanner) == ["b", "b"] && log.events.allSatisfy { $0.total == 1 })
        let plain = try await ScanEngine(registry: r).scan(.test(t))
        #expect(plain.items.isEmpty && plain.errors.isEmpty)
    }

    @Test("ItemCategory, Category'nin takma adı")
    func alias() {
        let c: ItemCategory = .apps
        #expect(c == CleanerKit.Category.apps)
        #expect(ItemCategory.allCases.count == CleanerKit.Category.allCases.count)
    }
}

// MARK: 3. Yetki gerektiren uygulamalar

@Suite("Yetki gerektiren uygulamalar")
struct AuthorizationTests {
    @Test("yazma gözlemi sınıflandırması: EPERM ve root yetki ister; diğerleri engelli")
    func classify() {
        #expect(PathPolicy.classify(AppWriteFacts(parentWritable: true, bundleErrno: nil, ownerUID: 0)) == .writable)
        if case .needsAuthorization = PathPolicy.classify(appManaged) {} else { Issue.record("EPERM") }
        if case .needsAuthorization = PathPolicy.classify(rootOwned) {} else { Issue.record("root") }
        if case .blocked = PathPolicy.classify(otherUser) {} else { Issue.record("başka kullanıcı") }
        let ownRO = AppWriteFacts(parentWritable: true, bundleErrno: EACCES, ownerUID: getuid())
        if case .blocked(let r) = PathPolicy.classify(ownRO) { #expect(r.contains("salt okunur")) } else { Issue.record("salt okunur") }
        // Üst klasöre yazılamıyorsa yetkiyle de açılmaz.
        let parentRO = AppWriteFacts(parentWritable: false, bundleErrno: EPERM, ownerUID: 0)
        if case .blocked = PathPolicy.classify(parentRO) {} else { Issue.record("üst klasör") }
        let rofs = AppWriteFacts(parentWritable: true, bundleErrno: EROFS, ownerUID: 0)
        if case .blocked = PathPolicy.classify(rofs) {} else { Issue.record("EROFS") }
    }

    @Test("gerçek gözlem: kendi salt okunur paketi engelli, yetki istemez")
    func liveProbe() throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        let foo = try AppFixture.app(t, in: apps, "Foo", id: "com.example.foo")
        #expect(p.appBundleWriteAccess(for: foo) == .writable)
        chmod(foo.path, 0o555)
        if case .blocked = p.appBundleWriteAccess(for: foo) {} else { Issue.record("salt okunur engelli olmalı") }
        #expect(p.appBundleRejectionReason(for: foo, allowingAuthorization: true) != nil)
        chmod(foo.path, 0o755)
    }

    @Test("tarayıcı: korumalı/root uygulama kilitlenmez, yetki işaretli ve seçili değil; diğer kilitler önce gelir")
    func scanner() async throws {
        let t = try TempTree()
        let (apps, basePolicy) = try AppFixture.setup(t)
        var policy = basePolicy
        let now = Date().addingTimeInterval(400 * 86_400)
        try AppFixture.app(t, in: apps, "Managed", id: "com.example.managed")
        try AppFixture.app(t, in: apps, "RootApp", id: "com.example.rootapp")
        try AppFixture.app(t, in: apps, "Other", id: "com.example.other")
        let running = try AppFixture.app(t, in: apps, "RunMgd", id: "com.example.runmgd")
        try AppFixture.app(t, in: apps, "AppleMgd", id: "com.apple.mgd")
        try AppFixture.app(t, in: apps, "Plain", id: "com.example.plain")
        policy.writeProbe = probe(["Managed.app": appManaged, "RootApp.app": rootOwned, "Other.app": otherUser,
                                   "RunMgd.app": appManaged, "AppleMgd.app": appManaged])
        var ctx = ScanContext.test(t, now: now, signals: Signals(
            commands: FakeCommands(),
            processes: PathProcesses(list: [
                RunningProcess(pid: 9, name: "RunMgd", path: running.appending(path: "Contents/MacOS/RunMgd").path),
            ]),
            spotlight: FakeSpotlight(), fileDates: LiveFileDates(), git: FakeGit()))
        ctx.pathPolicy = policy
        let items = try await AppsScanner(binDirectories: []).scan(ctx)
        let by = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(Set(by.keys) == ["Managed", "RootApp", "Other", "RunMgd", "Plain"])
        for n in ["Managed", "RootApp"] {
            let i = try #require(by[n])
            #expect(i.needsAuthorization == true && i.lockReason == nil && i.risk == .yellow, "\(n)")
            #expect(i.preselect == false && !i.isDefaultSelected)
            #expect(i.note?.contains("macOS parola ya da Touch ID isteyecek") == true)
        }
        #expect(by["Other"]?.lockReason?.contains("başka kullanıcı") == true && by["Other"]?.needsAuthorization == nil)
        #expect(by["RunMgd"]?.lockReason == "çalışıyor" && by["RunMgd"]?.needsAuthorization == nil)
        #expect(by["Plain"]?.needsAuthorization == nil && by["Plain"]?.preselect == nil)

        // Codable geriye uyumlu: alan olmadan da çözülür; alanla gidip gelir.
        let enc = try JSONEncoder().encode(by["Managed"]!)
        #expect(try JSONDecoder().decode(CleanItem.self, from: enc) == by["Managed"]!)
        var json = try #require(try JSONSerialization.jsonObject(with: enc) as? [String: Any])
        json.removeValue(forKey: "needsAuthorization")
        let old = try JSONDecoder().decode(CleanItem.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(old.needsAuthorization == nil)
    }

    /// Yetki işaretli uygulama öğesi (taze tarama sonucu gibi).
    func authItem(_ url: URL, related: [URL] = []) -> CleanItem {
        var i = AppFixture.appItem(url, related: related)
        i.needsAuthorization = true
        i.preselect = false
        return i
    }

    func trasher(_ p: PathPolicy, _ t: TempTree, normal: Counter, privileged: Counter?,
                 processes: PathProcesses = PathProcesses(), selfBundleID: String? = nil) throws -> Trasher {
        Trasher(policy: p, commands: FakeCommands(), processes: processes, selfExecutable: nil, selfBundleID: selfBundleID,
                recycler: try FakeRecycler(t, name: "FakeTrash", counter: normal),
                privilegedRecycler: try privileged.map { try FakeRecycler(t, name: "PrivTrash", counter: $0) })
    }

    @Test("yetkili taşıyıcı yoksa (CLI) reddedilir; dry-run da")
    func noPrivileged() async throws {
        let t = try TempTree()
        let (apps, basePolicy) = try AppFixture.setup(t)
        var p = basePolicy
        let foo = try AppFixture.app(t, in: apps, "Foo", id: "com.example.foo")
        p.writeProbe = probe(["Foo.app": appManaged])
        let normal = Counter()
        let tr = try trasher(p, t, normal: normal, privileged: nil)
        for dry in [true, false] {
            let r = await tr.trash([authItem(foo)], dryRun: dry)
            #expect(r.done.isEmpty && r.refused.map(\.reason) == [Trasher.authorizationRefusal], "\(r)")
        }
        #expect(normal.n == 0 && t.exists(foo))
        // Varsayılan public init de yetkili taşıyıcı vermez.
        let cli = Trasher(policy: p, commands: FakeCommands())
        #expect(cli.rejectionReason(for: authItem(foo)) == Trasher.authorizationRefusal)
    }

    @Test("paket yetkili taşıyıcıyla, artıklar normal taşıyıcıyla taşınır")
    func privilegedMove() async throws {
        let t = try TempTree()
        let (apps, basePolicy) = try AppFixture.setup(t)
        var p = basePolicy
        let foo = try AppFixture.app(t, in: apps, "Foo", id: "com.example.foo")
        let bar = try AppFixture.app(t, in: t.home.appending(path: "Applications"), "Bar", id: "com.example.bar")
        let caches = try t.dir("Library/Caches/com.example.foo")
        let prefs = try t.file("Library/Preferences/com.example.foo.plist")
        p.writeProbe = probe(["Foo.app": rootOwned, "Bar.app": appManaged])
        let (normal, privileged) = (Counter(), Counter())
        let tr = try trasher(p, t, normal: normal, privileged: privileged)
        let items = [authItem(foo, related: [caches, prefs]), authItem(bar)]

        let dry = await tr.trash(items)
        #expect(dry.refused.isEmpty && dry.done.count == 4, "\(dry)")
        #expect(normal.n == 0 && privileged.n == 0)

        let r = await tr.trash(items, dryRun: false)
        #expect(r.refused.isEmpty, "\(r.refused)")
        #expect(privileged.log.sorted() == [bar.path, foo.path].sorted())
        #expect(normal.log == [caches.path, prefs.path])
        #expect(r.done.first { $0.path == foo.path }?.detail?.contains("PrivTrash") == true)
        for u in [foo, bar, caches, prefs] { #expect(!t.exists(u)) }
    }

    @Test("taşıma anında dar istisna yeniden doğrulanır; yetkili taşıyıcı başka hiçbir yol için çağrılmaz")
    func revalidation() async throws {
        let t = try TempTree()
        let (apps, basePolicy) = try AppFixture.setup(t)
        var p = basePolicy
        let running = try AppFixture.app(t, in: apps, "Run", id: "com.example.run")
        let apple = try AppFixture.app(t, in: apps, "Notes", id: "com.apple.Notes")
        let me = try AppFixture.app(t, in: apps, "Me", id: "com.example.me")
        let nested = try AppFixture.app(t, in: try t.dir("Utilities", in: apps), "Deep", id: "com.example.deep")
        let target = try AppFixture.app(t, in: apps, "Target", id: "com.example.target")
        let link = apps.appending(path: "Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let blocked = try AppFixture.app(t, in: apps, "Blocked", id: "com.example.blocked")
        let nowWritable = try AppFixture.app(t, in: apps, "NowOK", id: "com.example.nowok")
        let cacheDir = try t.dir("Library/Caches/x")
        let docs = try t.file("Documents/tez.docx")
        p.writeProbe = probe(["Run.app": appManaged, "Notes.app": appManaged, "Me.app": appManaged,
                              "Deep.app": appManaged, "Link.app": appManaged, "Blocked.app": otherUser])
        let (normal, privileged) = (Counter(), Counter())
        let tr = try trasher(p, t, normal: normal, privileged: privileged, processes: PathProcesses(list: [
            RunningProcess(pid: 1, name: "Run", path: running.appending(path: "Contents/MacOS/Run").path),
        ]), selfBundleID: "com.example.me")
        // Başka kategoride yetki işareti: reddedilir.
        var cacheItem = CleanItem(category: .caches, name: "x", path: cacheDir.path, allocatedBytes: 1, risk: .green)
        cacheItem.needsAuthorization = true
        var docItem = CleanItem(category: .largeOld, name: "tez", path: docs.path, allocatedBytes: 1, risk: .red)
        docItem.needsAuthorization = true
        // Uygulama dışı yol `apps` kategorisinde yetki işaretiyle.
        let fakeApp = authItem(try t.dir("Library/Caches/y"))
        let items = [authItem(running), authItem(apple), authItem(me), authItem(nested), authItem(link),
                     authItem(blocked), cacheItem, docItem, fakeApp]
        let r = await tr.trash(items, dryRun: false)
        #expect(r.done.isEmpty, "\(r.done)")
        #expect(r.refused.count == items.count, "\(r.refused)")
        let reasons = Dictionary(uniqueKeysWithValues: r.refused.map { ($0.path, $0.reason) })
        #expect(reasons[running.path] == "çalışıyor")
        #expect(reasons[apple.path]?.contains("Apple") == true)
        #expect(reasons[me.path] == "Cleaner'ın kendisi")
        #expect(reasons[nested.path]?.contains("doğrudan çocuğu değil") == true)
        #expect(reasons[link.path]?.contains("sembolik") == true)
        #expect(reasons[blocked.path]?.contains("başka kullanıcı") == true)
        #expect(reasons[cacheDir.path] != nil && reasons[docs.path]?.contains("yetki işareti") == true)
        #expect(privileged.n == 0 && normal.n == 0)

        // Taramada yetki işareti yokken taşıma anında korumalı görünen paket normal yoldan reddedilir.
        var q = p
        q.writeProbe = probe(["NowOK.app": appManaged])
        let tr2 = try trasher(q, t, normal: normal, privileged: privileged)
        let r2 = await tr2.trash([AppFixture.appItem(nowWritable)], dryRun: false)
        #expect(r2.done.isEmpty && r2.refused.first?.reason.contains("Uygulama Yönetimi") == true, "\(r2)")
        #expect(privileged.n == 0 && normal.n == 0)
        for u in [running, apple, me, nested, target, blocked, nowWritable, cacheDir, docs] { #expect(t.exists(u)) }
    }

    @Test("dışarıdan gelen öğenin yetki işareti taramayla aynı olmalı")
    func externalFlag() async throws {
        let t = try TempTree()
        let (apps, basePolicy) = try AppFixture.setup(t)
        var p = basePolicy
        let foo = try AppFixture.app(t, in: apps, "Foo", id: "com.example.foo")
        p.writeProbe = probe(["Foo.app": appManaged])
        let (normal, privileged) = (Counter(), Counter())
        let tr = try trasher(p, t, normal: normal, privileged: privileged)
        let scanned = AppFixture.appItem(foo) // taramada işaretsiz
        let forged = authItem(foo)
        let r = await tr.trash([forged], dryRun: false, scanItems: [scanned])
        #expect(r.done.isEmpty && r.refused.first?.reason == "öğe tarama sonucundan farklı")
        // id ile giriş: kararlar tarama öğesiyle (işaretsiz) verilir, yetkili taşıyıcı kullanılmaz.
        let r2 = await tr.trash(ids: [scanned.id], scan: [scanned], dryRun: false)
        #expect(r2.done.isEmpty && r2.refused.count == 1, "\(r2)")
        #expect(privileged.n == 0 && normal.n == 0 && t.exists(foo))
    }
}

// MARK: 4. Bunu tut

private func dupItems(_ g: String, keeper: URL, others: [URL], keeperLock: String? = nil) -> [CleanItem] {
    var k = CleanItem(category: .duplicates, name: keeper.lastPathComponent, path: keeper.path, allocatedBytes: 0,
                      risk: .info, method: .none, groupID: g, keeperPath: keeper.path)
    k.ifNotKeptRisk = .green
    k.ifNotKeptLockReason = keeperLock
    return [k] + others.map {
        CleanItem(category: .duplicates, name: $0.lastPathComponent, path: $0.path, allocatedBytes: 4096,
                  risk: .green, method: .trash, groupID: g, keeperPath: keeper.path)
    }
}

@Suite("Mükerrer: Bunu tut")
struct KeeperTests {
    func setup() throws -> (TempTree, URL, URL, URL, Trasher, Counter) {
        let t = try TempTree()
        let a = try t.file("Documents/a.bin")
        let b = try t.file("Downloads/b.bin")
        let c = try t.file("Desktop/c.bin")
        let moved = Counter()
        let tr = Trasher(policy: PathPolicy(home: t.home), commands: FakeCommands(),
                         recycler: try FakeRecycler(t, name: "FakeTrash", counter: moved))
        return (t, a, b, c, tr, moved)
    }

    @Test("başka kopya tutulunca varsayılan tutulacak taşınabilir, tutulan taşınmaz")
    func override() async throws {
        let (t, a, b, c, tr, moved) = try setup()
        let scan = dupItems("g1", keeper: a, others: [b, c])
        let ids = scan.map(\.id)
        // Seçimsiz: a (varsayılan tutulacak) taşınamaz.
        let before = await tr.trash(ids: [ids[0]], scan: scan)
        #expect(before.done.isEmpty && before.refused.count == 1)

        let r = await tr.trash(ids: ids, scan: scan, dryRun: false, keepers: ["g1": b.path])
        #expect(Set(r.done.map(\.path)) == [a.path, c.path], "\(r)")
        #expect(r.refused.map(\.path) == [b.path]) // tutulan kopya seçildiyse reddedilir
        #expect(r.done.first { $0.path == a.path }!.bytes > 0)
        #expect(t.exists(b) && !t.exists(a) && !t.exists(c) && moved.n == 2)
    }

    @Test("öğe tabanlı giriş de aynı; tutulacak yol grubun üyesi değilse grubun bütün öğeleri reddedilir")
    func invalidKeeper() async throws {
        let (t, a, b, c, tr, moved) = try setup()
        let other = try t.file("Documents/other.bin")
        let scan = dupItems("g1", keeper: a, others: [b, c]) + dupItems("g2", keeper: other, others: [])
        for keeper in [other.path, "/etc/passwd", t.home.appending(path: "Documents/yok.bin").path, ""] {
            let r = await tr.trash(ids: scan.map(\.id), scan: scan, dryRun: false, keepers: ["g1": keeper])
            #expect(r.done.isEmpty, "\(keeper): \(r.done)")
            #expect(Set(r.refused.filter { $0.reason.contains("üyesi değil") }.map(\.path)) == [a.path, b.path, c.path])
        }
        let r2 = await tr.trash(scan, dryRun: false, scanItems: scan, keepers: ["g1": other.path])
        #expect(r2.done.isEmpty)
        let r3 = await tr.trash([scan[0], scan[2]], dryRun: false, scanItems: scan, keepers: ["g1": b.path])
        #expect(Set(r3.done.map(\.path)) == [a.path, c.path] && r3.refused.isEmpty, "\(r3)")
        #expect(moved.n == 2 && t.exists(b) && t.exists(other))
    }

    @Test("son kopya kuralı aynen geçerli; kilitli varsayılan tutulacak yine taşınmaz; tutulanı içeren üst öğe reddedilir")
    func rules() async throws {
        let (t, a, b, c, tr, moved) = try setup()
        // Tutulan b tarama ile taşıma arasında silindi: a ve c'den biri kalmalı.
        let scan = dupItems("g1", keeper: a, others: [b, c])
        try FileManager.default.removeItem(at: b)
        let r = await tr.trash(ids: [scan[0].id, scan[2].id], scan: scan, dryRun: false, keepers: ["g1": b.path])
        #expect(r.done.count == 1 && r.refused.count == 1 && r.refused[0].reason.contains("son kopyası"), "\(r)")
        #expect(t.exists(a) || t.exists(c))

        // Git'te takipli varsayılan tutulacak: başka kopya tutulsa da kilitli.
        let t2 = try TempTree()
        let x = try t2.file("Documents/x.bin")
        let y = try t2.file("Documents/y.bin")
        let moved2 = Counter()
        let tr2 = Trasher(policy: PathPolicy(home: t2.home), commands: FakeCommands(),
                          recycler: try FakeRecycler(t2, name: "FakeTrash", counter: moved2))
        let s2 = dupItems("g", keeper: x, others: [y], keeperLock: "Git deposunda takipli")
        let r2 = await tr2.trash(ids: [s2[0].id], scan: s2, dryRun: false, keepers: ["g": y.path])
        #expect(r2.done.isEmpty && r2.refused.first?.reason.contains("takipli") == true, "\(r2)")

        // Tutulan kopyayı içeren üst klasör öğesi taşınmaz.
        let dir = try t2.dir("Projeler/eski")
        let z = try t2.file("Projeler/eski/z.bin")
        let s3 = dupItems("h", keeper: x, others: [z])
            + [CleanItem(category: .largeOld, name: "eski", path: dir.path, allocatedBytes: 1, risk: .red)]
        let r3 = await tr2.trash(ids: [s3[2].id, s3[0].id], scan: s3, dryRun: false, keepers: ["h": z.path])
        #expect(r3.refused.contains { $0.path == dir.path && $0.reason.contains("tutulacak") }, "\(r3)")
        #expect(t2.exists(dir) && t2.exists(z))
        #expect(moved2.log == [x.path])
        _ = moved
    }

    @Test("tarayıcı tutulacak kopyaya 'tutulmazsa' riskini yazar")
    func scannerFields() async throws {
        let t = try TempTree()
        try t.file("Documents/a.bin", bytes: 4000)
        try t.file("Downloads/b.bin", bytes: 4000)
        try t.file("Music/c.bin", bytes: 4000)
        let items = try await DuplicatesScanner(minBytes: 1024, prefixBytes: 64).scan(.test(t))
        let keeper = try #require(items.first { $0.isDuplicateKeeper })
        #expect(keeper.path.hasSuffix("Documents/a.bin") && keeper.ifNotKeptRisk == .green && keeper.ifNotKeptLockReason == nil)
        #expect(items.first { $0.path.hasSuffix("Music/c.bin") }?.risk == .yellow)
        #expect(items.filter { !$0.isDuplicateKeeper }.allSatisfy { $0.ifNotKeptRisk == nil })
    }
}

// MARK: 5. Son kopya uç durumu

@Suite("Mükerrer son kopya: üst klasör uç durumu")
struct GroupRuleEdgeTests {
    @Test("tutulacak silinmiş, bir kopya taşınan üst klasörde: kapsanmayan kopya reddedilir")
    func uncoveredPicked() async throws {
        let t = try TempTree()
        let k = try t.file("Documents/k.bin")
        let bDir = try t.dir("Eski")
        let a = try t.file("Eski/a.bin")
        let b = try t.file("Masa/b.bin")
        let scan = dupItems("g", keeper: k, others: [b, a])
            + [CleanItem(category: .caches, name: "Eski", path: bDir.path, allocatedBytes: 10, risk: .green)]
        try FileManager.default.removeItem(at: k)
        let moved = Counter()
        let tr = Trasher(policy: PathPolicy(home: t.home), commands: FakeCommands(),
                         recycler: try FakeRecycler(t, name: "FakeTrash", counter: moved))
        // Sıra: b, a, üst klasör (eski kod a'yı reddeder, a üst klasörle gider, b de gider).
        let r = await tr.trash(ids: [scan[1].id, scan[2].id, scan[3].id], scan: scan, dryRun: false)
        #expect(r.refused.map(\.path) == [b.path], "\(r)")
        #expect(t.exists(b) && !t.exists(a) && !t.exists(bDir))
    }

    @Test("kapsanmayan seçilen kopya yoksa üst öğe (ve içindeki kopya) reddedilir")
    func parentRejected() async throws {
        let t = try TempTree()
        let k = try t.file("Documents/k.bin")
        let dir = try t.dir("Eski")
        let a = try t.file("Eski/a.bin")
        let b = try t.file("Masa/b.bin")
        let scan = dupItems("g", keeper: k, others: [b, a])
            + [CleanItem(category: .caches, name: "Eski", path: dir.path, allocatedBytes: 10, risk: .green)]
        try FileManager.default.removeItem(at: k)
        try FileManager.default.removeItem(at: b)
        let moved = Counter()
        let tr = Trasher(policy: PathPolicy(home: t.home), commands: FakeCommands(),
                         recycler: try FakeRecycler(t, name: "FakeTrash", counter: moved))
        for ids in [[scan[2].id, scan[3].id], [scan[3].id]] {
            let r = await tr.trash(ids: ids, scan: scan, dryRun: false)
            #expect(r.done.isEmpty, "\(r.done)")
            #expect(r.refused.contains { $0.path == dir.path && $0.reason.contains("son kopyası var") }, "\(r.refused)")
        }
        #expect(t.exists(a) && t.exists(dir) && moved.n == 0)
    }
}
