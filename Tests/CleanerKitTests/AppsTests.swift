import Foundation
import Testing
@testable import CleanerKit

/// Uygulama istisnası ve uygulama tarayıcısı. Gerçek /Applications'a dokunulmaz: uygulama kökü geçici klasördür,
/// taşıma geçici "FakeTrash"e yapılır.
enum AppFixture {
    /// Geçici uygulama kökü ve bu kökle kurulmuş politika.
    static func setup(_ t: TempTree) throws -> (apps: URL, policy: PathPolicy) {
        let apps = try t.dir("Applications", in: t.root)
        try t.dir("Applications") // ~/Applications
        let policy = PathPolicy(home: t.home, appRoots: [apps, t.home.appending(path: "Applications")])
        return (apps, policy)
    }

    @discardableResult
    static func app(_ t: TempTree, in root: URL, _ name: String, id: String, version: String = "1.0",
                    extras: [String] = [], bytes: Int = 8192) throws -> URL {
        let bundle = try t.dir("\(name).app", in: root)
        try t.file("Contents/MacOS/\(name)", bytes: bytes, in: bundle)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleName": name]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.appending(path: "Contents/Info.plist"))
        for e in extras { try t.dir("Contents/" + e, in: bundle) }
        return bundle
    }

    static func mover(_ t: TempTree, counter: Counter) throws -> @Sendable (URL) throws -> URL? {
        let bin = try t.dir("FakeTrash", in: t.root)
        return { url in
            counter.hit(url.path)
            let dest = bin.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
    }

    static func appItem(_ url: URL, related: [URL] = [], category: CleanerKit.Category = .apps) -> CleanItem {
        CleanItem(category: category, name: url.lastPathComponent, path: url.path, allocatedBytes: 1000,
                  risk: .yellow, method: .trash, relatedPaths: related.map(\.path))
    }

    /// Uygulamaya bağlı artık öğesi (taze tarama sonucu gibi).
    static func leftover(_ url: URL, app: CleanItem, bundleID: String, match: LeftoverMatch = .bundleID,
                         key: String? = nil) -> CleanItem {
        CleanItem(category: .apps, name: url.lastPathComponent, path: url.path, allocatedBytes: 10,
                  risk: match == .bundleID ? .green : .yellow, method: .trash, preselect: false,
                  parentAppID: app.id, leftoverMatch: match, appBundleID: bundleID, matchedName: key)
    }
}

struct PathProcesses: ProcessListing {
    var list: [RunningProcess] = []
    func runningProcesses() -> [RunningProcess] { list }
}

@Suite("Uygulama istisnası (PathPolicy)")
struct AppPolicyTests {
    @Test("yalnız uygulama kökünün doğrudan çocuğu olan gerçek .app kabul edilir")
    func boundary() throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        let foo = try AppFixture.app(t, in: apps, "Foo", id: "com.example.foo")
        let bar = try AppFixture.app(t, in: t.home.appending(path: "Applications"), "Bar", id: "com.example.bar")
        #expect(p.appBundleRejectionReason(for: foo) == nil)
        #expect(p.appBundleRejectionReason(for: bar) == nil)
        // Listelenebilir; ama genel taşıma yolu (başka kategori) uygulama kökünde her şeyi reddeder.
        #expect(p.protectionReason(for: foo) == nil)
        #expect(p.trashRejectionReason(for: foo) != nil)
        #expect(p.trashRejectionReason(for: bar) != nil)
        #expect(p.trashRejectionReason(for: t.home.appending(path: "Applications/Bar.app/Contents")) != nil)

        let utilities = try t.dir("Utilities", in: apps)
        let terminal = try AppFixture.app(t, in: utilities, "Terminal", id: "com.example.terminal")
        try t.dir("Klasor", in: apps)
        try t.file("not.txt", in: apps)
        try t.dir(".app", in: apps)
        let rejected: [URL] = [
            apps, // kökün kendisi
            t.home.appending(path: "Applications"),
            URL(fileURLWithPath: apps.path + "/../etc"), // .. ile kaçış
            URL(fileURLWithPath: apps.path + "/Foo.app/../../home/Documents"),
            foo.appending(path: "Contents/MacOS/Foo"), // paket içi
            foo.appending(path: "Contents"),
            terminal, // alt klasör
            apps.appending(path: "Klasor"), apps.appending(path: "not.txt"), apps.appending(path: ".app"),
            apps.appending(path: "Yok.app"), // var olmayan
            URL(fileURLWithPath: "/System/Applications/Calculator.app"),
            URL(fileURLWithPath: "/Applications/Safari.app"), // enjekte kökler dışında
            URL(fileURLWithPath: "/etc"), URL(fileURLWithPath: "/"),
            t.home.appending(path: "Documents/Foo.app"),
        ]
        for u in rejected {
            #expect(p.appBundleRejectionReason(for: u) != nil, "reddedilmeliydi: \(u.path)")
        }
    }

    @Test("sembolik bağlantı ile kaçış reddedilir")
    func symlinkEscapes() throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        let fm = FileManager.default
        // Paketin kendisi bağlantı: /Applications/Evil.app -> ~/Documents
        let docs = try t.dir("Documents")
        try t.file("onemli.txt", in: docs)
        let evil = apps.appending(path: "Evil.app")
        try fm.createSymbolicLink(at: evil, withDestinationURL: docs)
        #expect(p.appBundleRejectionReason(for: evil) != nil)
        // Alt klasör bağlantısı: /Applications/Sub -> başka yer, içinde X.app
        let elsewhere = try t.dir("elsewhere", in: t.root)
        try AppFixture.app(t, in: elsewhere, "X", id: "com.example.x")
        try fm.createSymbolicLink(at: apps.appending(path: "Sub"), withDestinationURL: elsewhere)
        #expect(p.appBundleRejectionReason(for: apps.appending(path: "Sub/X.app")) != nil)
        // Ana klasördeki bağlantı üzerinden aynı pakete erişim: yazıldığı haliyle kök değil.
        try AppFixture.app(t, in: apps, "Foo", id: "com.example.foo")
        try fm.createSymbolicLink(at: t.home.appending(path: "kacis"), withDestinationURL: apps)
        #expect(p.appBundleRejectionReason(for: t.home.appending(path: "kacis/Foo.app")) != nil)
        // Uygulama kökünün kendisi bağlantı (/Applications -> başka yer).
        let realRoot = try t.dir("gercek-kok", in: t.root)
        let app = try AppFixture.app(t, in: realRoot, "Y", id: "com.example.y")
        let linkRoot = t.root.appending(path: "BagliApplications")
        try fm.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)
        let lp = PathPolicy(home: t.home, appRoots: [linkRoot])
        #expect(lp.appBundleRejectionReason(for: linkRoot.appending(path: "Y.app")) != nil)
        #expect(t.exists(app))
        // Kök, ana klasörün başka bir yerine çözülüyor (ör. ~/Documents).
        try AppFixture.app(t, in: docs, "Z", id: "com.example.z")
        let dp = PathPolicy(home: t.home, appRoots: [docs])
        #expect(dp.appBundleRejectionReason(for: docs.appending(path: "Z.app")) != nil)
    }

    @Test("yazılamayan paket (root'a ait gibi) ve yazılamayan kök reddedilir")
    func notWritable() throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        let foo = try AppFixture.app(t, in: apps, "Foo", id: "com.example.foo")
        chmod(foo.path, 0o555)
        #expect(p.appBundleRejectionReason(for: foo)?.contains("yazma izni") == true)
        #expect(p.appBundleWriteProblem(for: foo) != nil)
        chmod(foo.path, 0o755)
        #expect(p.appBundleRejectionReason(for: foo) == nil)
        chmod(apps.path, 0o555)
        #expect(p.appBundleRejectionReason(for: foo)?.contains("yazma izni") == true)
        chmod(apps.path, 0o755)
    }

    @Test("artık yalnız izinli ~/Library klasöründe ve bundle id ile tam eşleşirse")
    func leftovers() throws {
        let t = try TempTree()
        let (_, p) = try AppFixture.setup(t)
        let id = "com.example.foo"
        let ok = [
            try t.dir("Library/Application Support/\(id)"), try t.dir("Library/Caches/\(id)"),
            try t.dir("Library/Containers/\(id)"), try t.file("Library/Preferences/\(id).plist"),
            try t.dir("Library/Saved Application State/\(id).savedState"),
            try t.dir("Library/HTTPStorages/\(id)"), try t.file("Library/HTTPStorages/\(id).binarycookies"),
            try t.dir("Library/WebKit/\(id)"), try t.dir("Library/Logs/\(id)"),
            try t.dir("Library/Group Containers/group.\(id)"), try t.dir("Library/Group Containers/ABCDE12345.\(id)"),
            try t.dir("Library/Group Containers/ABCDE12345.group.\(id)"),
        ]
        for u in ok { #expect(p.leftoverRejectionReason(for: u, bundleID: id) == nil, "izinli olmalıydı: \(u.path)") }
        let bad = [
            try t.dir("Library/Group Containers/UBF8T346G9.Office"), // paylaşılan grup
            try t.dir("Library/Group Containers/abcde12345.\(id)"), // takım öneki büyük harf olmalı
            try t.dir("Library/Group Containers/ABCDE1234.\(id)"), // 9 karakter
            try t.dir("Library/Application Support/Foo"), // adla tahmin
            try t.dir("Library/Caches/\(id).helper"), // önek eşleşmesi değil tam eşleşme
            try t.dir("Library/Application Support/\(id)/alt"), // doğrudan çocuk değil
            try t.dir("Documents/\(id)"), try t.dir(".ssh"), t.home.appending(path: "Library/Keychains/\(id)"),
            try t.file("Library/Preferences/\(id)"), // .plist değil
            t.home.appending(path: "Library/Caches/../Caches/\(id)/../../Documents"),
            t.home, t.home.appending(path: "Library/Caches"),
        ]
        for u in bad { #expect(p.leftoverRejectionReason(for: u, bundleID: id) != nil, "reddedilmeliydi: \(u.path)") }
        // Geçersiz ya da Apple bundle id.
        #expect(p.leftoverRejectionReason(for: ok[1], bundleID: "../..") != nil)
        #expect(p.leftoverRejectionReason(for: t.home.appending(path: "Library/Caches/com.apple.x"), bundleID: "com.apple.x") != nil)
        // ~/Library/Caches bağlantıyla dışarı gidiyorsa artık kabul edilmez.
        let t2 = try TempTree()
        let outside = try t2.dir("dis", in: t2.root)
        try t2.dir("x.y", in: outside)
        try t2.dir("Library")
        try FileManager.default.createSymbolicLink(at: t2.home.appending(path: "Library/Caches"), withDestinationURL: outside)
        let p2 = PathPolicy(home: t2.home, appRoots: [])
        #expect(p2.leftoverRejectionReason(for: t2.home.appending(path: "Library/Caches/x.y"), bundleID: "x.y") != nil)
    }

    @Test("bundle id doğrulama ve Apple tanıma")
    func bundleIDs() {
        #expect(AppBundleInfo.isValidBundleID("com.microsoft.VSCode"))
        #expect(AppBundleInfo.isValidBundleID("org.foo-bar_baz.App2"))
        for bad in ["", ".", "..", "../x", "a/b", ".hidden", "com.foo bar", "çay.com"] {
            #expect(!AppBundleInfo.isValidBundleID(bad), "\(bad)")
        }
        #expect(AppBundleInfo.isAppleBundleID("com.apple.Safari"))
        #expect(AppBundleInfo.isAppleBundleID("COM.APPLE.dt.Xcode"))
        #expect(!AppBundleInfo.isAppleBundleID("com.applesauce.x"))
    }
}

@Suite("Uygulama taşıma (Trasher)")
struct AppTrasherTests {
    func trasher(_ p: PathPolicy, _ t: TempTree, moved: Counter, processes: PathProcesses = PathProcesses(),
                 selfExecutable: URL? = nil, selfBundleID: String? = nil) throws -> Trasher {
        Trasher(policy: p, commands: FakeCommands(), processes: processes, selfExecutable: selfExecutable,
                selfBundleID: selfBundleID, mover: try AppFixture.mover(t, counter: moved))
    }

    @Test("uygulama ve seçilen artık öğeleri taşınır (uygulama önce); seçilmeyen ve paylaşılan kalır")
    func moveWithLeftovers() async throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        let id = "com.example.foo"
        // ~/Applications'taki paket (derinlik 4), ana klasördeki gizli artıktan (derinlik 3) derin: yine önce taşınır.
        let foo = try AppFixture.app(t, in: t.home.appending(path: "Applications"), "Foo", id: id)
        let caches = try t.dir("Library/Caches/\(id)")
        let prefs = try t.file("Library/Preferences/\(id).plist")
        let group = try t.dir("Library/Group Containers/ABCDE12345.\(id)")
        let dot = try t.dir(".foo")
        let shared = try t.dir("Library/Group Containers/UBF8T346G9.Office")
        let unselected = try t.dir("Library/Logs/\(id)")
        let moved = Counter()
        let tr = try trasher(p, t, moved: moved)
        let app = AppFixture.appItem(foo)
        let left = [caches, prefs, group].map { AppFixture.leftover($0, app: app, bundleID: id) }
            + [AppFixture.leftover(dot, app: app, bundleID: id, match: .name, key: "foo1")]
        // Adı eşleşmeyen anahtarla (".foo" ~ "foo1") ad tabanlı artık reddedilir.
        let scan = [app] + left
        let dry = await tr.trash(scan)
        #expect(dry.refused.map(\.path) == [dot.path], "\(dry.refused)")
        #expect(dry.done.count == 4 && moved.n == 0 && t.exists(foo))

        let fooDot = try t.dir(".fooapp-cli")
        let nameItem = AppFixture.leftover(fooDot, app: app, bundleID: id, match: .name, key: "fooapp")
        let scan2 = [left[2], app, left[0], left[1], nameItem, AppFixture.leftover(unselected, app: app, bundleID: id)]
        let r = await tr.trash(Array(scan2.prefix(5)), dryRun: false, scanItems: scan2)
        #expect(r.refused.isEmpty, "\(r.refused)")
        #expect(r.done.first?.path == foo.path)
        #expect(Set(r.done.map(\.path)) == [foo.path, caches.path, prefs.path, group.path, fooDot.path])
        for u in [foo, caches, prefs, group, fooDot] { #expect(!t.exists(u)) }
        for u in [shared, unselected, dot] { #expect(t.exists(u)) }
        #expect(r.done.allSatisfy { $0.detail?.contains("FakeTrash") == true })
    }

    @Test("Apple, çalışan (yol, bundle id, ad), Cleaner'ın kendisi reddedilir")
    func refusals() async throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        let appleApp = try AppFixture.app(t, in: apps, "Notes", id: "com.apple.Notes")
        let runPath = try AppFixture.app(t, in: apps, "RunPath", id: "com.example.runpath")
        let runID = try AppFixture.app(t, in: apps, "RunID", id: "com.example.runid")
        // Aynı bundle id'li başka kopya ~/Applications'tan çalışıyor.
        let copy = try AppFixture.app(t, in: t.home.appending(path: "Applications"), "RunIDCopy", id: "com.example.runid")
        let runName = try AppFixture.app(t, in: apps, "RunName", id: "com.example.runname")
        let me = try AppFixture.app(t, in: apps, "Cleaner", id: "com.example.cleaner")
        let meByID = try AppFixture.app(t, in: apps, "CleanerKopya", id: "com.example.cleaner2")
        let fine = try AppFixture.app(t, in: apps, "Fine", id: "com.example.fine")
        let processes = PathProcesses(list: [
            RunningProcess(pid: 1, name: "Helper", path: runPath.appending(path: "Contents/Frameworks/H.app/Contents/MacOS/Helper").path),
            RunningProcess(pid: 2, name: "RunIDCopy", path: copy.appending(path: "Contents/MacOS/RunIDCopy").path),
            RunningProcess(pid: 3, name: "RunName", path: nil),
        ])
        let moved = Counter()
        let tr = try trasher(p, t, moved: moved, processes: processes,
                             selfExecutable: me.appending(path: "Contents/MacOS/Cleaner"), selfBundleID: "com.example.cleaner2")
        let targets = [appleApp, runPath, runID, copy, runName, me, meByID]
        let r = await tr.trash(targets.map { AppFixture.appItem($0) } + [AppFixture.appItem(fine)], dryRun: false)
        #expect(r.refused.count == targets.count, "\(r.refused)")
        #expect(r.done.map(\.path) == [fine.path])
        let reasons = Dictionary(uniqueKeysWithValues: r.refused.map { ($0.path, $0.reason) })
        #expect(reasons[appleApp.path]?.contains("Apple") == true)
        for u in [runPath, runID, copy, runName] { #expect(reasons[u.path] == "çalışıyor", "\(u.path): \(reasons[u.path] ?? "-")") }
        #expect(reasons[me.path] == "Cleaner'ın kendisi")
        #expect(reasons[meByID.path] == "Cleaner'ın kendisi")
        for u in targets { #expect(t.exists(u)) }
    }

    @Test("kötüye kullanım: yanlış kategori, uydurma artık, istisna dışı yol")
    func abuse() async throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        let foo = try AppFixture.app(t, in: apps, "Foo", id: "com.example.foo")
        let ssh = try t.dir(".ssh")
        let docs = try t.file("Documents/tez.docx")
        let otherCache = try t.dir("Library/Caches/com.example.other")
        let terminal = try AppFixture.app(t, in: try t.dir("Utilities", in: apps), "Terminal", id: "com.example.terminal")
        let cacheDir = try t.dir("Library/Caches/x")
        let homeApp = try AppFixture.app(t, in: t.home.appending(path: "Applications"), "Bar", id: "com.example.bar")
        let items = [
            AppFixture.appItem(foo, category: .largeOld), // uygulama başka kategoriden
            AppFixture.appItem(homeApp, category: .caches), // ~/Applications başka kategoriden
            AppFixture.appItem(cacheDir), // apps kategorisinde uygulama olmayan yol
            AppFixture.appItem(terminal),
            AppFixture.appItem(URL(fileURLWithPath: apps.path + "/../etc")),
            AppFixture.appItem(foo.appending(path: "Contents")),
            AppFixture.appItem(foo, related: [ssh]),
        ]
        let moved = Counter()
        let tr = try trasher(p, t, moved: moved)
        let r = await tr.trash(items, dryRun: false)
        #expect(r.done.isEmpty, "\(r.done)")
        #expect(r.refused.count == items.count - 1, "\(r.refused)") // foo iki kez: aynı id bir kez işlenir
        // Aynı id'nin ikinci kopyası atlanır; uydurma artıklı öğeyi ayrıca dene.
        for related in [[ssh], [docs], [otherCache], [t.home], [t.home.appending(path: "Library/Caches")]] {
            let r2 = await tr.trash([AppFixture.appItem(foo, related: related)], dryRun: false)
            #expect(r2.done.isEmpty && r2.refused.count == 1, "\(related): \(r2)")
        }
        // Başka kategoride ilişkili yol taşınamaz.
        var cacheItem = CleanItem(category: .caches, name: "x", path: cacheDir.path, allocatedBytes: 1, risk: .green)
        cacheItem.relatedPaths = [ssh.path]
        let r3 = await tr.trash([cacheItem], dryRun: false)
        #expect(r3.done.isEmpty)
        #expect(moved.n == 0)
        for u in [foo, ssh, docs, otherCache, terminal, cacheDir, homeApp] { #expect(t.exists(u)) }
    }

    @Test("uygulama izin hatası (CLI, yetkili taşıyıcı yok): Uygulama Yönetimi metni; bağlı artık atlanır")
    func permissionErrorOnMove() async throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        let foo = try AppFixture.app(t, in: apps, "Foo", id: "com.example.foo")
        let caches = try t.dir("Library/Caches/com.example.foo")
        let other = try t.dir("Library/Caches/x")
        let tr = Trasher(policy: p, commands: FakeCommands(), processes: PathProcesses(), selfExecutable: nil,
                         selfBundleID: nil, mover: { _ in throw CocoaError(.fileWriteNoPermission) })
        let app = AppFixture.appItem(foo)
        let left = AppFixture.leftover(caches, app: app, bundleID: "com.example.foo")
        let r = await tr.trash([app, left], dryRun: false)
        #expect(r.done.isEmpty)
        let reasons = Dictionary(uniqueKeysWithValues: r.refused.map { ($0.path, $0.reason) })
        #expect(reasons[foo.path] == Trasher.appManagementRefusal, "\(r.refused)")
        #expect(reasons[caches.path] == Trasher.appFailedSkip)
        #expect(t.exists(foo) && t.exists(caches))
        // Uygulama dışı öğenin izin hatası eski metinle.
        let r2 = await tr.trash([CleanItem(category: .caches, name: "x", path: other.path, allocatedBytes: 1, risk: .green)], dryRun: false)
        #expect(r2.refused.first?.reason.contains("izin yok") == true)
    }
}

@Suite("Uygulama tarayıcısı")
struct AppsScannerTests {
    @Test("risk, kilit, artıklar ve notlar")
    func scan() async throws {
        let t = try TempTree()
        let (apps, policy) = try AppFixture.setup(t)
        let now = Date().addingTimeInterval(400 * 86_400) // her şey "eski" görünsün
        let fm = FileManager.default

        let old = try AppFixture.app(t, in: apps, "Old", id: "com.example.old", extras: ["_MASReceipt"])
        try t.file("Library/Caches/com.example.old/c.bin", bytes: 100_000)
        try t.file("Library/Preferences/com.example.old.plist", bytes: 100)
        try t.dir("Library/Group Containers/ABCDE12345.com.example.old")
        try t.dir("Library/Group Containers/UBF8T346G9.Office")
        try t.dir("Library/Application Support/Old") // adla eşleşen
        let never = try AppFixture.app(t, in: apps, "Never", id: "com.example.never", extras: ["Library/LoginItems"])
        let recent = try AppFixture.app(t, in: apps, "Recent", id: "com.example.recent")
        try AppFixture.app(t, in: apps, "Apple", id: "com.apple.something")
        let running = try AppFixture.app(t, in: apps, "Running", id: "com.example.running")
        let cli = try AppFixture.app(t, in: apps, "Cli", id: "com.example.cli")
        try AppFixture.app(t, in: apps, "Active", id: "com.example.active")
        let activePrefs = try t.file("Library/Preferences/com.example.active.plist", bytes: 100)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-5 * 86_400)], ofItemAtPath: activePrefs.path)
        let locked = try AppFixture.app(t, in: apps, "RootOwned", id: "com.example.root")
        chmod(locked.path, 0o555)
        let homeApp = try AppFixture.app(t, in: t.home.appending(path: "Applications"), "HomeApp", id: "com.example.home")
        try AppFixture.app(t, in: try t.dir("Utilities", in: apps), "Deep", id: "com.example.deep")
        try fm.createSymbolicLink(at: apps.appending(path: "Link.app"), withDestinationURL: old)
        try t.dir("NoPlist.app", in: apps)

        let bin = try t.dir("bin", in: t.root)
        try fm.createSymbolicLink(at: bin.appending(path: "cli"), withDestinationURL: cli.appending(path: "Contents/MacOS/Cli"))

        var ctx = ScanContext.test(t, now: now, signals: Signals(
            commands: FakeCommands(),
            processes: PathProcesses(list: [
                RunningProcess(pid: 9, name: "Running", path: running.appending(path: "Contents/MacOS/Running").path),
            ]),
            spotlight: FakeSpotlight(dates: [
                old.path: now.addingTimeInterval(-200 * 86_400),
                recent.path: now.addingTimeInterval(-10 * 86_400),
            ]),
            fileDates: LiveFileDates(),
            git: FakeGit()
        ))
        ctx.pathPolicy = policy
        let items = try await AppsScanner(binDirectories: [bin]).scan(ctx)
        let appItems = items.filter { !$0.isLeftover }
        let leftoverItems = items.filter(\.isLeftover)
        let byName = Dictionary(uniqueKeysWithValues: appItems.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["Old", "Never", "Recent", "Running", "Cli", "Active", "RootOwned", "HomeApp"])
        #expect(items.allSatisfy { $0.category == .apps && !$0.isDefaultSelected })

        let o = try #require(byName["Old"])
        #expect(o.risk == .yellow && o.lockReason == nil && o.dateSignal == .opened(days: 200))
        #expect(o.relatedPaths == nil)
        let oLeft = leftoverItems.filter { $0.parentAppID == o.id }
        let oExact = oLeft.filter { $0.leftoverMatch == .bundleID }
        #expect(oExact.count == 3, "\(oLeft.map(\.path))")
        #expect(oExact.allSatisfy { $0.risk == .green && $0.preselect == false && !$0.isDefaultSelected && $0.appBundleID == "com.example.old" })
        #expect(!oLeft.contains { $0.path.contains("UBF8T346G9") })
        // "Old" 3 karakter: ad tabanlı aramaya girmez.
        #expect(!oLeft.contains { $0.leftoverMatch == .name })
        #expect(o.allocatedBytes < 100_000 && (o.leftoverBytes ?? 0) > 100_000)
        #expect(o.note?.contains("App Store") == true && o.note?.contains("Yeniden indirilir") == true)
        #expect(o.note?.contains("artıklar: 3 kesin, 0 ad benzerliği") == true)

        let n = try #require(byName["Never"])
        #expect(n.risk == .yellow && n.dateSignal == .unknown && n.relatedPaths == nil)
        #expect(n.note?.contains("kendi kaldırıcısı önerilir (LoginItems)") == true)
        #expect(byName["Recent"]?.risk == .info)
        #expect(byName["Running"]?.lockReason == "çalışıyor")
        #expect(byName["Cli"]?.lockReason == "Komut satırından kullanılıyor (cli)")
        #expect(byName["Active"]?.lockReason?.contains("son 5 günde") == true)
        #expect(byName["RootOwned"]?.lockReason?.contains("yazma izni") == true)
        #expect(byName["HomeApp"]?.risk == .yellow && byName["HomeApp"]?.path == homeApp.path)

        // Tarayıcı çıktısı Trasher'dan geçer (dry-run); kilitli/bilgi reddedilir.
        let tr = Trasher(policy: policy, commands: FakeCommands(), processes: PathProcesses(), selfExecutable: nil,
                         selfBundleID: nil, mover: { _ in Issue.record("taşınmamalıydı"); return nil })
        let r = await tr.trash(items)
        #expect(Set(r.done.filter { $0.detail == nil }.map(\.path)) == [old.path, never.path, homeApp.path])
        #expect(r.done.filter { $0.detail == "artık" }.count == 3)
        // 5 kilitli/bilgi uygulama + Active'in kilitli kesin artığı.
        #expect(r.refused.count == 6, "\(r.refused)")
        #expect(leftoverItems.first { $0.path.hasSuffix("com.example.active.plist") }?.lockReason?.hasPrefix("uygulama kilitli") == true)
        _ = recent
    }

    @Test("kayıt: apps tarayıcısı çekirdekte kayıtlı")
    func registered() {
        let r = CleanerRegistry.makeDefault()
        #expect(r.cleaners.contains { $0.id == "apps" && $0.categories == [.apps] })
    }
}
