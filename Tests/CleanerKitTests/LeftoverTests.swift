import AppKit
import CoreServices
import Foundation
import Testing
@testable import CleanerKit

/// Uygulama artıkları ayrı öğe (kesin + ad tabanlı), taşıma anı doğrulaması, toplu yetkili taşıma.
/// Yalnız geçici klasör; gerçek /Applications, gerçek Çöp Kutusu ve gerçek Apple Event yok.

/// Toplu çağrıları kaydeden sahte taşıyıcı. `failing`: yerinde kalacak yollar; `batchError`: olay hatası.
final class BatchRecorder: Recycling, @unchecked Sendable {
    let bin: URL
    private let lock = NSLock()
    private var _batches: [[String]] = []
    private var _singles: [String] = []
    var failing: Set<String> = []
    var batchError: (any Error)?

    init(_ t: TempTree, name: String) throws { bin = try t.dir(name, in: t.root) }

    var batches: [[String]] { lock.withLock { _batches } }
    var singles: [String] { lock.withLock { _singles } }

    func recycle(_ url: URL) async throws -> URL? {
        lock.withLock { _singles.append(url.path) }
        return try move(url)
    }

    func recycle(_ urls: [URL]) async -> [URL: Result<URL?, any Error>] {
        lock.withLock { _batches.append(urls.map(\.path)) }
        var out: [URL: Result<URL?, any Error>] = [:]
        for u in urls {
            if let batchError { out[u] = .failure(batchError); continue }
            if failing.contains(u.path) { out[u] = .failure(FinderRecycleError.stillExists); continue }
            do { out[u] = .success(try move(u)) } catch { out[u] = .failure(error) }
        }
        return out
    }

    private func move(_ url: URL) throws -> URL {
        let dest = bin.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }
}

private func writeInfo(_ bundle: URL, _ plist: [String: Any]) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: bundle.appending(path: "Contents/Info.plist"))
}

private func scanApps(_ t: TempTree, _ policy: PathPolicy, processes: [RunningProcess] = []) async throws -> [CleanItem] {
    var ctx = ScanContext.test(t, now: Date().addingTimeInterval(400 * 86_400), signals: Signals(
        commands: FakeCommands(), processes: PathProcesses(list: processes), spotlight: FakeSpotlight(),
        fileDates: LiveFileDates(), git: FakeGit()))
    ctx.pathPolicy = policy
    return try await AppsScanner(binDirectories: []).scan(ctx)
}

@Suite("Ad kuralları")
struct LeftoverNameRuleTests {
    @Test("normalize, genel ad ve eşleşme biçimleri")
    func rules() {
        #expect(LeftoverNames.normalize("Antigravity IDE") == "antigravityide")
        #expect(LeftoverNames.normalize("zoom.us_x-y") == "zoomusxy")
        for bad in ["app", "code", "google", "microsoft", "apple", "helper", "update", "abc", "electron", "x/y"] {
            #expect(!LeftoverNames.isUsableKey(LeftoverNames.normalize(bad)), "\(bad)")
        }
        #expect(LeftoverNames.isUsableKey("antigravity"))
        func m(_ e: String, _ p: String, _ k: String, dir: Bool = true) -> Bool {
            LeftoverNames.matches(entry: e, parent: p, key: k, isDirectory: dir)
        }
        #expect(m(".antigravity", "", "antigravity"))
        #expect(m(".antigravity", "", "antigravity", dir: false)) // tam ad dosya da olabilir
        #expect(m(".antigravity-ide", "", "antigravity"))
        #expect(!m(".antigravity-ide", "", "antigravity", dir: false)) // önek yalnız klasörde
        #expect(m(".antigravity-ide", "", "antigravityide"))
        #expect(!m("antigravity", "", "antigravity")) // gizli değil
        #expect(!m(".antigravityx", "", "antigravity"))
        #expect(m("Antigravity IDE", "Library/Application Support", "antigravityide"))
        #expect(!m("Antigravity-x", "Library/Caches", "antigravity")) // önek yalnız ~
        #expect(m("Antigravity.plist", "Library/Preferences", "antigravity"))
        #expect(!m("Antigravity", "Library/Preferences", "antigravity"))
    }

    @Test("PathPolicy: yalnız izinli klasörlerin doğrudan çocuğu; Containers, iCloud, bağlantı, iç içe yok")
    func policy() throws {
        let t = try TempTree()
        let (_, p) = try AppFixture.setup(t)
        let key = "zeplin"
        let ok = [
            try t.dir("Library/Application Support/Zeplin"), try t.dir("Library/Caches/zeplin"),
            try t.file("Library/Preferences/Zeplin.plist"), try t.dir("Library/Logs/Zeplin"),
            try t.dir("Library/Saved Application State/Zeplin.savedState"), try t.dir("Library/HTTPStorages/Zeplin"),
            try t.dir("Library/WebKit/Zeplin"), try t.dir(".zeplin"), try t.dir(".zeplin-cli"),
        ]
        for u in ok { #expect(p.nameLeftoverRejectionReason(for: u, key: key) == nil, "\(u.path)") }
        let mobile = try t.dir("Library/Mobile Documents/Zeplin")
        let link = t.home.appending(path: "Library/Caches/Zeplin2")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: mobile)
        let bad = [
            try t.dir("Library/Containers/Zeplin"), try t.dir("Library/Group Containers/Zeplin"), mobile,
            try t.dir("Library/Application Support/Zeplin/Zeplin"), try t.dir("Documents/Zeplin"),
            try t.dir("Zeplin"), // gizli değil
            try t.dir("Library/Caches/ZeplinX"), t.home.appending(path: "Library/Caches/Yok"),
            try t.file(".zeplin-cfg"), // önek eşleşmesi dosyada değil
            try t.dir(".zeplin-token"), try t.file(".zeplin-env"), // kimlik bilgisi sözcüğü
            URL(fileURLWithPath: t.home.path + "/Library/Caches/../Caches/zeplin/../../../.ssh"),
        ]
        for u in bad { #expect(p.nameLeftoverRejectionReason(for: u, key: key) != nil, "\(u.path)") }
        #expect(p.nameLeftoverRejectionReason(for: link, key: "zeplin2") == "sembolik bağlantı")
        #expect(p.nameLeftoverRejectionReason(for: ok[0], key: "code") != nil)
        // Soket ad tabanlı artık olamaz.
        let sock = t.home.appending(path: ".zeplin-cli.sock")
        #expect(mkfifo(sock.path, 0o600) == 0)
        #expect(p.nameLeftoverRejectionReason(for: sock, key: key) == "klasör ya da dosya değil")
        // ~/Library/Caches bağlantıyla dışarı gidiyorsa ad tabanlı artık da kabul edilmez.
        let t2 = try TempTree()
        let outside = try t2.dir("dis", in: t2.root)
        try t2.dir("Zeplin", in: outside)
        try t2.dir("Library")
        try FileManager.default.createSymbolicLink(at: t2.home.appending(path: "Library/Caches"), withDestinationURL: outside)
        let p2 = PathPolicy(home: t2.home, appRoots: [])
        #expect(p2.nameLeftoverRejectionReason(for: t2.home.appending(path: "Library/Caches/Zeplin"), key: key) != nil)
    }
}

@Suite("Artık tarayıcısı")
struct LeftoverScannerTests {
    @Test("kesin ve ad tabanlı artıklar ayrı öğe; çakışan kurulu uygulama, genel ad, Containers, bağlantı, iCloud hariç")
    func findsLeftovers() async throws {
        let t = try TempTree()
        let (apps, policy) = try AppFixture.setup(t)
        let ag = try AppFixture.app(t, in: apps, "Antigravity", id: "com.google.antigravity")
        let ide = try AppFixture.app(t, in: apps, "Antigravity IDE", id: "com.google.antigravity-ide")
        try writeInfo(ide, ["CFBundleIdentifier": "com.google.antigravity-ide", "CFBundleName": "Antigravity IDE",
                            "CFBundleExecutable": "Electron"])
        // Genel adlı uygulama: ad tabanlı arama yok.
        try AppFixture.app(t, in: apps, "Code", id: "com.example.code")
        // Apple uygulaması alt klasörde (listelenmez ama çakışmada sayılır).
        try AppFixture.app(t, in: try t.dir("Utilities", in: apps), "Notes Helper", id: "com.apple.noteshelper")
        let notesApp = try AppFixture.app(t, in: apps, "Notesy", id: "com.example.notesy")
        try writeInfo(notesApp, ["CFBundleIdentifier": "com.example.notesy", "CFBundleDisplayName": "Notes Helper"])

        let exact = [
            try t.dir("Library/Caches/com.google.antigravity"), try t.file("Library/Preferences/com.google.antigravity.plist"),
            try t.dir("Library/Containers/com.google.antigravity"),
            try t.dir("Library/Group Containers/ABCDE12345.com.google.antigravity"),
        ]
        let named = [
            try t.dir("Library/Application Support/Antigravity"), try t.file(".antigravity/argv.json", bytes: 50_000),
            try t.dir("Library/Logs/Antigravity"),
        ]
        let agDot = t.home.appending(path: ".antigravity")
        let ideDot = try t.dir(".antigravity-ide")
        let ideSupport = try t.dir("Library/Application Support/Antigravity IDE")
        let notInContainers = try t.dir("Library/Containers/Antigravity")
        let notInGroup = try t.dir("Library/Group Containers/Antigravity")
        let nested = try t.dir("Library/Application Support/Google/Antigravity")
        let mobile = try t.dir("Library/Mobile Documents/Antigravity")
        try FileManager.default.createSymbolicLink(at: t.home.appending(path: "Library/Caches/Antigravity"), withDestinationURL: mobile)
        let codeSupport = try t.dir("Library/Application Support/Code")
        let notesConflict = try t.dir("Library/Application Support/Notes Helper")

        let items = try await scanApps(t, policy)
        let appItems = Dictionary(uniqueKeysWithValues: items.filter { !$0.isLeftover }.map { ($0.name, $0) })
        let agItem = try #require(appItems["Antigravity"])
        let ideItem = try #require(appItems["Antigravity IDE"])
        #expect(agItem.relatedPaths == nil && agItem.leftoverMatch == nil && agItem.parentAppID == nil)
        let agLeft = items.filter { $0.parentAppID == agItem.id }
        let exactPaths = Set(agLeft.filter { $0.leftoverMatch == .bundleID }.map(\.path))
        #expect(exactPaths == Set(exact.map(\.path)), "\(exactPaths)")
        let namePaths = Set(agLeft.filter { $0.leftoverMatch == .name }.map(\.path))
        #expect(namePaths == Set([named[0], agDot, named[2]].map(\.path)), "\(namePaths)")
        for i in agLeft {
            #expect(i.category == .apps && i.preselect == false && !i.isDefaultSelected && i.lockReason == nil)
            #expect(i.appBundleID == "com.google.antigravity")
            if i.leftoverMatch == .bundleID {
                #expect(i.risk == .green && i.matchedName == nil)
            } else {
                #expect(i.risk == .yellow && i.matchedName == "antigravity")
                #expect(i.note?.contains("Adı benziyor; başka bir uygulamaya da ait olabilir") == true)
            }
        }
        #expect(agItem.leftoverBytes == agLeft.filter { $0.leftoverMatch == .bundleID }.reduce(0) { $0 + $1.allocatedBytes })
        #expect(agItem.allocatedBytes < 50_000)
        // `.antigravity-ide` Antigravity IDE ile de eşleştiği için Antigravity'ye aday değil; IDE'ye ait.
        let ideLeft = Set(items.filter { $0.parentAppID == ideItem.id }.map(\.path))
        #expect(ideLeft == [ideDot.path, ideSupport.path], "\(ideLeft)")
        let all = Set(items.map(\.path))
        for u in [notInContainers, notInGroup, nested, mobile, codeSupport, notesConflict,
                  t.home.appending(path: "Library/Caches/Antigravity")] {
            #expect(!all.contains(u.path), "\(u.path)")
        }
        #expect(items.filter { $0.name.hasPrefix("Code") }.count == 1)
    }

    @Test("çalışan uygulamanın artıkları kilitli")
    func runningLocks() async throws {
        let t = try TempTree()
        let (apps, policy) = try AppFixture.setup(t)
        let app = try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
        try t.dir("Library/Caches/io.zeplin.osx")
        try t.dir(".zeplin")
        let items = try await scanApps(t, policy, processes: [
            RunningProcess(pid: 5, name: "Zeplin", path: app.appending(path: "Contents/MacOS/Zeplin").path),
        ])
        let left = items.filter(\.isLeftover)
        #expect(left.count == 2)
        #expect(left.allSatisfy { $0.isLocked && $0.lockReason == "uygulama kilitli: çalışıyor" })
    }

    @Test("Codable: yeni alanlar gidip gelir; eski JSON (alansız) çözülür")
    func codable() throws {
        let app = CleanItem(category: .apps, name: "A", path: "/Applications/A.app", allocatedBytes: 1, risk: .yellow,
                            leftoverBytes: 42)
        let left = CleanItem(category: .apps, name: "A: .a", path: "/Users/u/.aaaa", allocatedBytes: 1, risk: .yellow,
                             preselect: false, parentAppID: app.id, leftoverMatch: .name, appBundleID: "x.a", matchedName: "aaaa")
        for i in [app, left] {
            #expect(try JSONDecoder().decode(CleanItem.self, from: try JSONEncoder().encode(i)) == i)
        }
        var json = try #require(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(left)) as? [String: Any])
        #expect(json["leftoverMatch"] as? String == "name")
        for k in ["parentAppID", "leftoverMatch", "appBundleID", "matchedName", "leftoverBytes"] { json.removeValue(forKey: k) }
        let old = try JSONDecoder().decode(CleanItem.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(old.parentAppID == nil && old.leftoverMatch == nil && !old.isLeftover && old.leftoverBytes == nil)
    }
}

@Suite("Artık taşıma")
struct LeftoverTrasherTests {
    func setup() throws -> (TempTree, PathPolicy, URL, CleanItem, [CleanItem]) {
        let t = try TempTree()
        let (apps, policy) = try AppFixture.setup(t)
        let app = try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
        let appItem = AppFixture.appItem(app)
        let exact = AppFixture.leftover(try t.dir("Library/Caches/io.zeplin.osx"), app: appItem, bundleID: "io.zeplin.osx")
        let named = AppFixture.leftover(try t.dir(".zeplin"), app: appItem, bundleID: "io.zeplin.osx", match: .name, key: "zeplin")
        return (t, policy, app, appItem, [exact, named])
    }

    func trasher(_ p: PathPolicy, _ t: TempTree, _ moved: Counter, processes: [RunningProcess] = [],
                 privileged: BatchRecorder? = nil) throws -> Trasher {
        Trasher(policy: p, commands: FakeCommands(), processes: PathProcesses(list: processes), selfExecutable: nil,
                selfBundleID: nil, mover: try AppFixture.mover(t, counter: moved), privilegedRecycler: privileged)
    }

    @Test("artık uygulama seçilmeden tek başına taşınır; uygulama bu arada silinmişse de (sahipsiz)")
    func alone() async throws {
        let (t, p, app, appItem, left) = try setup()
        let moved = Counter()
        let tr = try trasher(p, t, moved)
        let scan = [appItem] + left
        let r = await tr.trash(ids: [left[1].id], scan: scan, dryRun: false)
        #expect(r.refused.isEmpty && r.done.map(\.path) == [left[1].path], "\(r)")
        #expect(t.exists(app) && t.exists(left[0].url) && !t.exists(left[1].url))
        // Uygulama elle kaldırıldı: kesin artık yine taşınır.
        try FileManager.default.removeItem(at: app)
        let r2 = await tr.trash(ids: [left[0].id], scan: scan, dryRun: false)
        #expect(r2.refused.isEmpty && !t.exists(left[0].url), "\(r2)")
    }

    @Test("taşıma anı yeniden doğrulama: bağlantıya dönüşen yol, sonradan kurulan çakışan uygulama, çalışan ve değişen uygulama")
    func revalidate() async throws {
        do { // yol taramadan sonra bağlantıya dönüştü
            let (t, p, _, appItem, left) = try setup()
            try FileManager.default.removeItem(at: left[1].url)
            let docs = try t.dir("Documents")
            try FileManager.default.createSymbolicLink(at: left[1].url, withDestinationURL: docs)
            let moved = Counter()
            let r = try await trasher(p, t, moved).trash(ids: [left[1].id], scan: [appItem] + left, dryRun: false)
            #expect(r.done.isEmpty && r.refused.first?.reason.contains("sembolik bağlantı") == true, "\(r)")
            #expect(moved.n == 0 && t.exists(docs))
        }
        do { // aynı adı taşıyan başka uygulama sonradan kuruldu
            let (t, p, _, appItem, left) = try setup()
            try AppFixture.app(t, in: t.home.appending(path: "Applications"), "Zeplin", id: "com.other.zeplin")
            let moved = Counter()
            let r = try await trasher(p, t, moved).trash(ids: [left[1].id], scan: [appItem] + left, dryRun: true)
            #expect(r.done.isEmpty && r.refused.first?.reason.contains("başka kurulu uygulama") == true, "\(r)")
        }
        do { // uygulama taşıma anında çalışıyor (ad ile)
            let (t, p, _, appItem, left) = try setup()
            let moved = Counter()
            let tr = try trasher(p, t, moved, processes: [RunningProcess(pid: 3, name: "Zeplin", path: nil)])
            let r = await tr.trash(ids: left.map(\.id), scan: [appItem] + left, dryRun: false)
            #expect(r.done.isEmpty && r.refused.count == 2 && r.refused.allSatisfy { $0.reason.contains("çalışıyor") }, "\(r)")
            #expect(moved.n == 0)
        }
        do { // paket yerinde ama bundle id değişti
            let (t, p, app, appItem, left) = try setup()
            try writeInfo(app, ["CFBundleIdentifier": "com.evil.other"])
            let moved = Counter()
            let r = try await trasher(p, t, moved).trash(ids: [left[0].id], scan: [appItem] + left, dryRun: false)
            #expect(r.done.isEmpty && r.refused.first?.reason.contains("uygulama değişti") == true, "\(r)")
        }
        do { // uygulama öğesi taramada yok / uydurma alanlar / tarama dışı öğe
            let (t, p, _, appItem, left) = try setup()
            let moved = Counter()
            let tr = try trasher(p, t, moved)
            let r = await tr.trash(ids: [left[0].id], scan: left, dryRun: false)
            #expect(r.refused.first?.reason.contains("uygulama öğesi bu taramada yok") == true, "\(r)")
            var forged = left[1]
            forged.leftoverMatch = .bundleID
            let r2 = await tr.trash([forged], dryRun: false, scanItems: [appItem] + left)
            #expect(r2.refused.first?.reason == "öğe tarama sonucundan farklı")
            // Ad tabanlı öğe ile korunan ya da ilgisiz yol taşınamaz (tarama öyle üretse bile).
            let ssh = try t.dir(".ssh")
            let docs = try t.dir("Documents/Zeplin")
            for u in [ssh, docs, t.home.appending(path: "Library/Containers")] {
                let bad = AppFixture.leftover(u, app: appItem, bundleID: "io.zeplin.osx", match: .name, key: "zeplin")
                let r3 = await tr.trash([bad], dryRun: false, scanItems: [appItem, bad])
                #expect(r3.done.isEmpty, "\(u.path)")
            }
            let apple = AppFixture.leftover(left[0].url, app: appItem, bundleID: "com.apple.zeplin")
            #expect(tr.rejectionReason(for: apple) != nil)
            #expect(moved.n == 0)
        }
    }

    @Test("uygulama taşınamazsa (yetki iptali) bağlı artıklar atlanır; başka uygulamanınki taşınır")
    func appFailureSkipsLeftovers() async throws {
        let (t, basePolicy, app, _, _) = try setup()
        var p = basePolicy
        p.writeProbe = AppWriteProbe { _, _ in AppWriteFacts(parentWritable: true, bundleErrno: EPERM, ownerUID: getuid()) }
        var appItem = AppFixture.appItem(app)
        appItem.needsAuthorization = true
        appItem.preselect = false
        let left = [AppFixture.leftover(t.home.appending(path: "Library/Caches/io.zeplin.osx"), app: appItem, bundleID: "io.zeplin.osx"),
                    AppFixture.leftover(t.home.appending(path: ".zeplin"), app: appItem, bundleID: "io.zeplin.osx", match: .name, key: "zeplin")]
        let priv = try BatchRecorder(t, name: "PrivTrash")
        priv.batchError = FinderRecycleError.userCancelled
        let moved = Counter()
        let tr = try trasher(p, t, moved, privileged: priv)
        let r = await tr.trash([appItem] + left, dryRun: false)
        #expect(r.done.isEmpty)
        let reasons = Dictionary(uniqueKeysWithValues: r.refused.map { ($0.path, $0.reason) })
        #expect(reasons[app.path]?.contains("iptal") == true)
        for l in left { #expect(reasons[l.path] == Trasher.appFailedSkip) }
        #expect(moved.n == 0 && priv.batches == [[app.path]] && priv.singles.isEmpty)
        for l in left { #expect(t.exists(l.url)) }
    }

    @Test("yetkili taşıyıcı artığa asla verilmez")
    func neverPrivilegedForLeftover() async throws {
        let (t, p, _, appItem, left) = try setup()
        let priv = try BatchRecorder(t, name: "PrivTrash")
        let moved = Counter()
        let tr = try trasher(p, t, moved, privileged: priv)
        var marked = left[0]
        marked.needsAuthorization = true
        #expect(tr.rejectionReason(for: marked) != nil)
        #expect(!tr.usesPrivilegedRecycler(marked))
        let r1 = await tr.trash([marked], dryRun: false, scanItems: [appItem, marked])
        #expect(r1.done.isEmpty)
        // Artık normal taşımada izin hatası alsa da yetkili yedeğe düşmez.
        let failing = Trasher(policy: p, commands: FakeCommands(), processes: PathProcesses(), selfExecutable: nil,
                              selfBundleID: nil, mover: { _ in throw CocoaError(.fileWriteNoPermission) }, privilegedRecycler: priv)
        let r2 = await failing.trash(ids: left.map(\.id), scan: [appItem] + left, dryRun: false)
        #expect(r2.done.isEmpty && r2.refused.count == 2 && r2.refused.allSatisfy { $0.reason.hasPrefix("artık taşınamadı") }, "\(r2)")
        #expect(priv.batches.isEmpty && priv.singles.isEmpty)
    }
}

@Suite("Toplu yetkili taşıma")
struct BatchPrivilegedTests {
    func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    @Test("toplu olay: tek core/delo, doğrudan nesne AEList, her öğe furl")
    func eventShape() throws {
        let urls = ["/Applications/A.app", "/Applications/B \"x\" & do shell script.app", "/Applications/C/../C.app"]
            .map { URL(fileURLWithPath: $0) }
        let e = FinderRecycler.makeDeleteEvent(for: urls)
        #expect(e.eventClass == fourCC("core") && e.eventID == fourCC("delo"))
        let direct = try #require(e.paramDescriptor(forKeyword: fourCC("----")))
        #expect(direct.descriptorType == fourCC("list"))
        #expect(direct.numberOfItems == 3)
        for i in 1...3 {
            let d = try #require(direct.atIndex(i))
            #expect(d.descriptorType == fourCC("furl"))
            #expect(d.fileURLValue?.path == urls[i - 1].standardizedFileURL.path)
        }
        #expect(e.numberOfItems == 1)
    }

    @Test("Finder toplu: kısmi başarı (biri yerinde kalır), olay hatası hepsine dağılır, tek gönderim")
    func finderBatch() async throws {
        let t = try TempTree()
        let a = try t.dir("Apps/A.app", in: t.root)
        let b = try t.dir("Apps/B.app", in: t.root)
        let bin = try t.dir("Bin", in: t.root)
        let calls = Counter(), singles = Counter()
        // Toplu olaydan sonra yerinde kalan B için tek öğeli olaya yedek düşülür (İP3); bu sahte de taşımaz.
        let rec = FinderRecycler(timeout: 5, sender: { u, _ in singles.hit(u.lastPathComponent); return nil },
                                 batchSender: { urls, _ in
                                     calls.hit()
                                     #expect(!Thread.isMainThread)
                                     try FileManager.default.moveItem(at: urls[0], to: bin.appending(path: "A.app"))
                                 })
        let r = await rec.recycle([a, b])
        #expect(calls.n == 1)
        #expect(singles.log == ["B.app"])
        if case .success = try #require(r[a]) {} else { Issue.record("A başarılı olmalıydı") }
        if case .failure(let e) = try #require(r[b]) { #expect(e as? FinderRecycleError == .stillExists) } else { Issue.record("B yerinde") }

        let c = try t.dir("Apps/C.app", in: t.root)
        let cancel = FinderRecycler(sender: { _, _ in nil }, batchSender: { _, _ in throw FinderRecycleError.userCancelled })
        let r2 = await cancel.recycle([b, c])
        for u in [b, c] {
            if case .failure(let e) = try #require(r2[u]) { #expect(e as? FinderRecycleError == .userCancelled) } else { Issue.record("iptal") }
        }
        #expect(await cancel.recycle([]).isEmpty)
    }

    @Test("Trasher: yetkili paketler tek toplu çağrıda; doğrulamadan geçemeyen listeye girmez; normal öğeler değişmez")
    func singleBatch() async throws {
        let t = try TempTree()
        let (apps, basePolicy) = try AppFixture.setup(t)
        var p = basePolicy
        p.writeProbe = AppWriteProbe { bundle, _ in
            (bundle as NSString).lastPathComponent == "Plain.app"
                ? AppWriteFacts(parentWritable: true, bundleErrno: nil, ownerUID: getuid())
                : AppWriteFacts(parentWritable: true, bundleErrno: EPERM, ownerUID: getuid())
        }
        let a = try AppFixture.app(t, in: apps, "Aaa", id: "com.example.aaa")
        let b = try AppFixture.app(t, in: apps, "Bbb", id: "com.example.bbb")
        let run = try AppFixture.app(t, in: apps, "Runner", id: "com.example.runner")
        let plain = try AppFixture.app(t, in: apps, "Plain", id: "com.example.plain")
        let cache = try t.dir("Library/Caches/x")
        func auth(_ u: URL) -> CleanItem {
            var i = AppFixture.appItem(u)
            i.needsAuthorization = true
            i.preselect = false
            return i
        }
        let aItem = auth(a)
        let aLeft = AppFixture.leftover(try t.dir("Library/Caches/com.example.aaa"), app: aItem, bundleID: "com.example.aaa")
        let items = [aItem, auth(b), auth(run), AppFixture.appItem(plain),
                     CleanItem(category: .caches, name: "x", path: cache.path, allocatedBytes: 1, risk: .green), aLeft]
        let priv = try BatchRecorder(t, name: "PrivTrash")
        priv.failing = [b.path]
        let moved = Counter()
        let tr = Trasher(policy: p, commands: FakeCommands(),
                         processes: PathProcesses(list: [RunningProcess(pid: 1, name: "Runner", path: nil)]),
                         selfExecutable: nil, selfBundleID: nil, mover: try AppFixture.mover(t, counter: moved),
                         privilegedRecycler: priv)
        let r = await tr.trash(items, dryRun: false)
        #expect(priv.batches == [[a.path, b.path]], "\(priv.batches)")
        #expect(priv.singles.isEmpty)
        #expect(Set(moved.log) == [plain.path, cache.path, aLeft.path], "\(moved.log)")
        let reasons = Dictionary(uniqueKeysWithValues: r.refused.map { ($0.path, $0.reason) })
        #expect(reasons[run.path] == "çalışıyor")
        #expect(reasons[b.path]?.contains("hâlâ yerinde") == true)
        #expect(Set(r.done.map(\.path)) == [a.path, plain.path, cache.path, aLeft.path])
        #expect(r.done.first { $0.path == a.path }?.detail?.contains("PrivTrash") == true)
        #expect(t.exists(b) && t.exists(run) && !t.exists(a))
    }

    @Test("yazılabilir görünen paket normal taşımada EPERM alırsa toplu yetkili çağrıya düşer; artık düşmez")
    func epermFallback() async throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        let a = try AppFixture.app(t, in: apps, "Aaa", id: "com.example.aaa")
        let b = try AppFixture.app(t, in: apps, "Bbb", id: "com.example.bbb")
        let aItem = AppFixture.appItem(a)
        let aLeft = AppFixture.leftover(try t.dir("Library/Caches/com.example.aaa"), app: aItem, bundleID: "com.example.aaa")
        let blocked = try t.dir("Library/Caches/blocked")
        let priv = try BatchRecorder(t, name: "PrivTrash")
        let bin = try t.dir("FakeTrash", in: t.root)
        let normalLog = Counter()
        // Normal taşıyıcı: .app paketlerinde ve "blocked"da EPERM, diğerlerinde taşır.
        let tr = Trasher(policy: p, commands: FakeCommands(), processes: PathProcesses(), selfExecutable: nil, selfBundleID: nil,
                         mover: { url in
                             normalLog.hit(url.path)
                             if url.path.hasSuffix(".app") || url.lastPathComponent == "blocked" {
                                 throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
                             }
                             let dest = bin.appending(path: UUID().uuidString)
                             try FileManager.default.moveItem(at: url, to: dest)
                             return dest
                         }, privilegedRecycler: priv)
        let items = [aItem, AppFixture.appItem(b), aLeft,
                     CleanItem(category: .caches, name: "b", path: blocked.path, allocatedBytes: 1, risk: .green)]
        let r = await tr.trash(items, dryRun: false)
        #expect(priv.batches == [[a.path, b.path]], "\(priv.batches)")
        #expect(Set(r.done.map(\.path)) == [a.path, b.path, aLeft.path], "\(r)")
        #expect(r.refused.map(\.path) == [blocked.path] && r.refused[0].reason.contains("izin yok"))
        // Artık normal taşıyıcıyla, uygulamadan sonra.
        #expect(normalLog.log.last == aLeft.path)

        // CLI (yetkili taşıyıcı yok): açık Uygulama Yönetimi metni, artık atlanır.
        let t2 = try TempTree()
        let (apps2, p2) = try AppFixture.setup(t2)
        let c = try AppFixture.app(t2, in: apps2, "Ccc", id: "com.example.ccc")
        let cItem = AppFixture.appItem(c)
        let cLeft = AppFixture.leftover(try t2.dir("Library/Caches/com.example.ccc"), app: cItem, bundleID: "com.example.ccc")
        let cli = Trasher(policy: p2, commands: FakeCommands(), processes: PathProcesses(), selfExecutable: nil,
                          selfBundleID: nil, mover: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) })
        let r2 = await cli.trash([cItem, cLeft], dryRun: false)
        #expect(r2.done.isEmpty)
        #expect(r2.refused.first { $0.path == c.path }?.reason == Trasher.appManagementRefusal)
        #expect(r2.refused.first { $0.path == cLeft.path }?.reason == Trasher.appFailedSkip)
    }
}
