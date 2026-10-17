import Foundation
import Testing
@testable import CleanerKit

/// İP3 taşıma yolu: Finder toplu olay güvenilirliği (tek öğeli olaya yedek), hata metinleri, Tam Disk Erişimi
/// yönlendirmesi, bağımsız CLI klasörü kararı. Gerçek Apple Event gönderilmez; yalnız geçici klasör.

private func move(_ url: URL, to bin: URL) throws {
    try FileManager.default.moveItem(at: url, to: bin.appending(path: UUID().uuidString + "-" + url.lastPathComponent))
}

private func failure(_ r: Result<URL?, any Error>?) -> FinderRecycleError? {
    if case .failure(let e) = r { return e as? FinderRecycleError }
    return nil
}

private func succeeded(_ r: Result<URL?, any Error>?) -> Bool {
    if case .success = r { return true }
    return false
}

@Suite("Finder: tek öğe ve toplu olaydan yedek")
struct FinderFallbackTests {
    @Test("tek öğeli liste doğrudan tek öğeli olayla gönderilir (toplu liste gönderilmez)")
    func singleUsesSingleEvent() async throws {
        let t = try TempTree()
        let a = try t.dir("Apps/A.app", in: t.root)
        let bin = try t.dir("Bin", in: t.root)
        let singles = Counter()
        let rec = FinderRecycler(timeout: 5, sender: { u, _ in singles.hit(u.path); try move(u, to: bin); return nil },
                                 batchSender: { _, _ in Issue.record("toplu gönderilmemeli") })
        let r = await rec.recycle([a])
        #expect(singles.n == 1 && succeeded(r[a]))
        #expect(!t.exists(a))
    }

    @Test("toplu olay başarı dedi ama öğeler yerinde: kalan her öğe tek öğeli olayla yeniden denenir")
    func stillExistsFallsBack() async throws {
        let t = try TempTree()
        let a = try t.dir("Apps/A.app", in: t.root)
        let b = try t.dir("Apps/B.app", in: t.root)
        let c = try t.dir("Apps/C.app", in: t.root)
        let bin = try t.dir("Bin", in: t.root)
        let singles = Counter(), batches = Counter()
        let rec = FinderRecycler(timeout: 5, sender: { u, _ in
            singles.hit(u.lastPathComponent)
            if u.lastPathComponent == "C.app" { return nil } // Finder başarı der ama taşımaz
            try move(u, to: bin)
            return nil
        }, batchSender: { urls, _ in
            batches.hit()
            try move(urls[0], to: bin) // yalnız A taşındı
        })
        let r = await rec.recycle([a, b, c])
        #expect(batches.n == 1)
        #expect(singles.log == ["B.app", "C.app"], "\(singles.log)")
        #expect(succeeded(r[a]) && succeeded(r[b]))
        #expect(failure(r[c]) == .stillExists)
        #expect(!t.exists(a) && !t.exists(b) && t.exists(c))
    }

    @Test("toplu olay Finder hatası (-10000) döndü: yedeğe düşülür; yedekte iptal gelirse kalanlar denenmez")
    func finderFailedFallsBackStopsOnCancel() async throws {
        let t = try TempTree()
        let a = try t.dir("Apps/A.app", in: t.root)
        let b = try t.dir("Apps/B.app", in: t.root)
        let c = try t.dir("Apps/C.app", in: t.root)
        let singles = Counter()
        let rec = FinderRecycler(timeout: 5, sender: { u, _ in
            singles.hit(u.lastPathComponent)
            throw FinderRecycleError.userCancelled
        }, batchSender: { _, _ in throw FinderRecycleError.finderFailed(code: -10000, message: "Handler failed") })
        let r = await rec.recycle([a, b, c])
        #expect(singles.n == 1, "iptalden sonra yeniden sorulmamalı: \(singles.log)")
        for u in [a, b, c] { #expect(failure(r[u]) == .userCancelled, "\(u.lastPathComponent)") }
        #expect(t.exists(a) && t.exists(b) && t.exists(c))
    }

    @Test("toplu olay iptal, Otomasyon izni yok, Finder yok ya da zaman aşımı: yedek denenmez")
    func noFallbackOnUserFacingErrors() async throws {
        for err in [FinderRecycleError.userCancelled, .automationDenied, .finderUnavailable, .timedOut] {
            let t = try TempTree()
            let a = try t.dir("Apps/A.app", in: t.root)
            let b = try t.dir("Apps/B.app", in: t.root)
            let rec = FinderRecycler(timeout: 5, sender: { _, _ in Issue.record("yedek denenmemeli: \(err)"); return nil },
                                     batchSender: { _, _ in throw err })
            let r = await rec.recycle([a, b])
            #expect(failure(r[a]) == err && failure(r[b]) == err)
        }
    }

    @Test("yedek kararı: yalnız stillExists ve Finder genel hatası")
    func fallbackDecision() {
        #expect(FinderRecycler.fallsBackToSingle(after: .stillExists))
        #expect(FinderRecycler.fallsBackToSingle(after: .finderFailed(code: -10000, message: nil)))
        #expect(!FinderRecycler.fallsBackToSingle(after: .userCancelled))
        #expect(!FinderRecycler.fallsBackToSingle(after: .automationDenied))
        #expect(!FinderRecycler.fallsBackToSingle(after: .timedOut))
        #expect(!FinderRecycler.fallsBackToSingle(after: .finderUnavailable))
    }
}

@Suite("Finder hata metinleri")
struct FinderErrorTextTests {
    @Test("atılan hatadaki Finder metni korunur; genel Cocoa metni alınmaz")
    func thrownMessage() {
        let withReason = NSError(domain: NSOSStatusErrorDomain, code: -10000,
                                 userInfo: [NSLocalizedFailureReasonErrorKey: "Finder got an error: Handler failed."])
        #expect(FinderRecycler.mapThrown(withReason) == .finderFailed(code: -10000, message: "Finder got an error: Handler failed."))
        #expect(FinderRecycler.mapThrown(NSError(domain: NSOSStatusErrorDomain, code: -10000)) == .finderFailed(code: -10000, message: nil))
        let nested = NSError(domain: "x", code: -5000, userInfo: [NSUnderlyingErrorKey: NSError(
            domain: NSOSStatusErrorDomain, code: -5000, userInfo: [NSLocalizedFailureReasonErrorKey: "erişim yok"])])
        #expect(FinderRecycler.mapThrown(nested).finderMessage == "erişim yok")
        // Bilinen kodlar sade Türkçe (Finder metni yerine).
        #expect(FinderRecycler.mapThrown(NSError(domain: NSOSStatusErrorDomain, code: -1743,
                                                 userInfo: [NSLocalizedFailureReasonErrorKey: "Not authorized"])) == .automationDenied)
    }

    @Test("bilinen kodlar Türkçe; Finder'ın mesajı varsa eklenir; kod alanı dolu")
    func descriptions() throws {
        let e = FinderRecycleError.finderFailed(code: -10000, message: "Handler failed")
        let d = try #require(e.errorDescription)
        #expect(d.contains("-10000") && d.contains("reddetti") && d.contains("Finder'ın mesajı: Handler failed"))
        #expect(FinderRecycleError.finderFailed(code: -5000, message: nil).errorDescription?.contains("erişim reddedildi") == true)
        #expect(FinderRecycleError.finderFailed(code: -1728, message: nil).errorDescription?.contains("bulamadı") == true)
        #expect(FinderRecycleError.finderFailed(code: -4242, message: nil).errorDescription == "Finder taşıyamadı (hata -4242)")
        #expect(FinderRecycleError.userCancelled.errorDescription?.contains("iptal") == true)
        #expect(FinderRecycleError.automationDenied.errorDescription?.contains("Otomasyon") == true)
        #expect(FinderRecycleError.userCancelled.code == -128 && FinderRecycleError.automationDenied.code == -1743)
        #expect(FinderRecycleError.stillExists.code == nil)
        #expect(FinderRecycler.mapError(code: -10000, message: "  \n") == .finderFailed(code: -10000, message: nil))
    }
}

@Suite("Tam Disk Erişimi yönlendirmesi")
struct FullDiskAccessRefusalTests {
    let eperm = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))

    @Test("uygulama verisi korumalı yolda EPERM: Tam Disk Erişimi; başka yerde yönetici izni")
    func describe() {
        let home = URL(fileURLWithPath: "/Users/biri")
        for rel in ["Library/Containers/com.microsoft.Word", "Library/Group Containers/UBF8T346G9.Office",
                    "Library/Containers"] {
            let r = Trasher.describe(eperm, path: "/Users/biri/" + rel, home: home)
            #expect(r.contains(Trasher.fullDiskAccessMarker) && !r.contains("yönetici"), "\(rel)")
        }
        let other = Trasher.describe(eperm, path: "/Users/biri/Library/Application Support/Foo", home: home)
        #expect(other.contains("yönetici izni") && !other.contains(Trasher.fullDiskAccessMarker))
        #expect(Trasher.describe(eperm).contains("yönetici izni"))
        // İzin hatası değilse yol ne olursa olsun olduğu gibi.
        let enoent = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        #expect(!Trasher.describe(enoent, path: "/Users/biri/Library/Containers/x", home: home).contains(Trasher.fullDiskAccessMarker))
        #expect(!Trasher.isFullDiskAccessProtected("/Users/biri/Library/ContainersX", home: home))
    }

    @Test("Trasher: Containers artığı EPERM ile taşınamazsa ret nedeni Tam Disk Erişimi der")
    func leftoverInContainers() async throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        let appURL = try AppFixture.app(t, in: apps, "Word", id: "com.microsoft.Word")
        let app = AppFixture.appItem(appURL)
        let box = try t.dir("Library/Containers/com.microsoft.Word")
        let left = AppFixture.leftover(box, app: app, bundleID: "com.microsoft.Word")
        let err = eperm
        let tr = Trasher(policy: p, commands: FakeCommands(), processes: PathProcesses(), selfExecutable: nil,
                         selfBundleID: nil, mover: { _ in throw err })
        let r = await tr.trash(ids: [left.id], scan: [app, left], dryRun: false)
        #expect(r.done.isEmpty && r.refused.count == 1, "\(r)")
        #expect(r.refused.first?.reason.contains(Trasher.fullDiskAccessMarker) == true, "\(r)")
        #expect(t.exists(box))
    }
}

@discardableResult
private func exe(_ t: TempTree, _ rel: String) throws -> URL {
    let u = try t.file(rel, bytes: 16)
    chmod(u.path, 0o755)
    return u
}

private func scanApps(_ t: TempTree, _ p: PathPolicy) async throws -> [CleanItem] {
    var ctx = ScanContext.test(t, now: Date().addingTimeInterval(400 * 86_400), signals: Signals(
        commands: FakeCommands(), processes: PathProcesses(), spotlight: FakeSpotlight(),
        fileDates: LiveFileDates(), git: FakeGit()))
    ctx.pathPolicy = PathPolicy(home: t.home, appRoots: p.appRoots) // komut klasörleri yeniden okunur
    return try await AppsScanner().scan(ctx)
}

@Suite("Bağımsız CLI klasörü (karar: asla ad artığı değil)")
struct StandaloneCLIFolderTests {
    @Test("~/.deno/bin/deno (sıradan çalıştırılabilir): aynı adlı uygulama kurulu olsa da aday değil")
    func denoNeverCandidate() async throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        try AppFixture.app(t, in: apps, "Deno", id: "land.deno.app")
        let dot = try t.dir(".deno")
        try exe(t, ".deno/bin/deno")
        #expect(LeftoverNames.isStandaloneCLIFolder(dot))
        #expect(p.nameLeftoverRejectionReason(for: dot, key: "deno") == LeftoverNames.standaloneCLIReason)
        #expect(!(try await scanApps(t, p)).contains { $0.path == dot.path })
    }

    @Test("bin/ içinde komut adı farklı ya da paket dışına bağlantı: yine bağımsız CLI")
    func otherNamesAndLinks() throws {
        let t = try TempTree()
        let a = try t.dir(".toolx")
        try exe(t, ".toolx/bin/something-else")
        #expect(LeftoverNames.isStandaloneCLIFolder(a))
        let b = try t.dir(".tooly")
        let real = try exe(t, ".tooly/libexec/tooly")
        try FileManager.default.createDirectory(at: b.appending(path: "bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: b.appending(path: "bin/tooly"), withDestinationURL: real)
        #expect(LeftoverNames.isStandaloneCLIFolder(b))
    }

    @Test("bağımsız değil: bin yok, bin boş ya da çalıştırılamaz dosya, bin dışarıya bağlantı, uygulama paketine bağlantı, kırık bağlantı")
    func notStandalone() throws {
        let t = try TempTree()
        let (apps, _) = try AppFixture.setup(t)
        let app = try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
        let none = try t.dir(".none")
        try t.file(".none/data.json")
        #expect(!LeftoverNames.isStandaloneCLIFolder(none))
        let empty = try t.dir(".empty/bin")
        #expect(!LeftoverNames.isStandaloneCLIFolder(empty.deletingLastPathComponent()))
        try t.file(".plain/bin/readme.txt")
        #expect(!LeftoverNames.isStandaloneCLIFolder(t.home.appending(path: ".plain")))
        // bin'in kendisi klasör dışına giden bağlantı (içeri giden bağlantı bağımsız sayılır: ayrı test).
        let realBin = try t.dir("elsewhere/bin")
        try exe(t, "elsewhere/bin/tool")
        let linked = try t.dir(".linked")
        try FileManager.default.createSymbolicLink(at: linked.appending(path: "bin"), withDestinationURL: realBin)
        #expect(!LeftoverNames.isStandaloneCLIFolder(linked))
        // Uygulamanın kendi CLI'ı (paket içine bağlantı) ve kırık bağlantı.
        let own = try t.dir(".zeplin/bin")
        try FileManager.default.createSymbolicLink(at: own.appending(path: "zeplin"),
                                                   withDestinationURL: app.appending(path: "Contents/MacOS/Zeplin"))
        chmod(app.appending(path: "Contents/MacOS/Zeplin").path, 0o755)
        try FileManager.default.createSymbolicLink(at: own.appending(path: "broken"),
                                                   withDestinationURL: t.root.appending(path: "yok"))
        #expect(!LeftoverNames.isStandaloneCLIFolder(own.deletingLastPathComponent()))
    }

    @Test("bin aynı klasörün içine bağlantı (versions/current/bin): gerçek klasör izlenir, bağımsız CLI; dışarıya ya da kendine giden değil")
    func binLinkInside() throws {
        let t = try TempTree()
        let v = try t.dir(".toolv")
        try exe(t, ".toolv/versions/1.2/bin/toolv")
        try FileManager.default.createSymbolicLink(atPath: v.appending(path: "versions/current").path,
                                                   withDestinationPath: "1.2")
        try FileManager.default.createSymbolicLink(atPath: v.appending(path: "bin").path,
                                                   withDestinationPath: "versions/current/bin")
        #expect(LeftoverNames.isStandaloneCLIFolder(v))
        // İçeri giden ama içinde çalıştırılabilir olmayan bin: bağımsız değil.
        let e = try t.dir(".toole")
        try t.file(".toole/versions/1/bin/readme.txt")
        try FileManager.default.createSymbolicLink(atPath: e.appending(path: "bin").path, withDestinationPath: "versions/1/bin")
        #expect(!LeftoverNames.isStandaloneCLIFolder(e))
        // Dışarıya (komşu ~/.<y>) giden göreli bağlantı: bağımsız değil.
        try exe(t, ".other/bin/tool")
        let out = try t.dir(".toolo")
        try FileManager.default.createSymbolicLink(atPath: out.appending(path: "bin").path, withDestinationPath: "../.other/bin")
        #expect(!LeftoverNames.isStandaloneCLIFolder(out))
        // Klasörün kendisine giden bağlantı (bin -> .): bağımsız değil.
        let selfLink = try t.dir(".tools")
        try exe(t, ".tools/tool")
        try FileManager.default.createSymbolicLink(atPath: selfLink.appending(path: "bin").path, withDestinationPath: ".")
        #expect(!LeftoverNames.isStandaloneCLIFolder(selfLink))
    }

    @Test("uygulamanın kendi CLI'ı ~/.<x>/bin içinde paket içine bağlantıysa: aday, kırmızı ve notlu (iç komut kuralı)")
    func ownAppCLIStaysRed() async throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        let app = try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
        chmod(app.appending(path: "Contents/MacOS/Zeplin").path, 0o755)
        let dot = try t.dir(".zeplin/bin").deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: dot.appending(path: "bin/zeplin"),
                                                   withDestinationURL: app.appending(path: "Contents/MacOS/Zeplin"))
        let i = try #require(try await scanApps(t, p).first { $0.path == dot.path }, "aday olmalı")
        #expect(i.risk == .red && i.note?.contains(AppsScanner.internalCommandMarker) == true, "\(i.note ?? "")")
    }

    @Test("Trasher: bağımsız CLI klasörü taşıma anında da reddedilir (tarama sonrası bin/ eklendiyse)")
    func trasherRejects() async throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        let appURL = try AppFixture.app(t, in: apps, "Deno", id: "land.deno.app")
        let app = AppFixture.appItem(appURL)
        let dot = try t.dir(".deno")
        try exe(t, ".deno/bin/deno")
        let left = AppFixture.leftover(dot, app: app, bundleID: "land.deno.app", match: .name, key: "deno")
        let moved = Counter()
        let tr = Trasher(policy: p, commands: FakeCommands(), processes: PathProcesses(), selfExecutable: nil,
                         selfBundleID: nil, mover: try AppFixture.mover(t, counter: moved))
        let r = await tr.trash(ids: [left.id], scan: [app, left], dryRun: false)
        #expect(r.done.isEmpty && r.refused.first?.reason.contains("bağımsız komut satırı") == true, "\(r)")
        #expect(moved.n == 0 && t.exists(dot))
    }
}

@Suite("Küçük notlar")
struct IP3SmallNotesTests {
    @Test("önek sınırı: ~/.zeplin2 'zeplin' ile eşleşmez; ~/.zeplin-old (klasör) eşleşir")
    func zeplinPrefixBoundary() async throws {
        #expect(!LeftoverNames.matches(entry: ".zeplin2", parent: "", key: "zeplin", isDirectory: true))
        #expect(LeftoverNames.matches(entry: ".zeplin-old", parent: "", key: "zeplin", isDirectory: true))
        #expect(!LeftoverNames.matches(entry: ".zeplin-old", parent: "", key: "zeplin", isDirectory: false))
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
        let two = try t.dir(".zeplin2")
        let old = try t.dir(".zeplin-old")
        let items = try await scanApps(t, p)
        #expect(!items.contains { $0.path == two.path })
        #expect(items.contains { $0.path == old.path })
    }

    @Test("taşıma anı: başka nedenle (git) kırmızı ama iç komut notu olmayan öğe 'yeniden tara' ile reddedilir")
    func redWithoutInternalNote() async throws {
        let t = try TempTree()
        let (apps, p0) = try AppFixture.setup(t)
        let appURL = try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
        chmod(appURL.appending(path: "Contents/MacOS/Zeplin").path, 0o755)
        let app = AppFixture.appItem(appURL)
        let dot = try t.dir(".zeplin/bin").deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: dot.appending(path: "bin/zeplin"),
                                                   withDestinationURL: appURL.appending(path: "Contents/MacOS/Zeplin"))
        let p = PathPolicy(home: t.home, appRoots: p0.appRoots)
        var gitRed = AppFixture.leftover(dot, app: app, bundleID: "io.zeplin.osx", match: .name, key: "zeplin")
        gitRed.risk = .red
        gitRed.note = AppsScanner.gitRepositoryNote
        var noted = gitRed
        noted.note = AppsScanner.internalCommandNote(["zeplin"]) + "; " + AppsScanner.gitRepositoryNote
        let moved = Counter()
        let tr = Trasher(policy: p, commands: FakeCommands(), processes: PathProcesses(), selfExecutable: nil,
                         selfBundleID: nil, mover: try AppFixture.mover(t, counter: moved))
        let bad = await tr.trash(ids: [gitRed.id], scan: [app, gitRed], dryRun: true)
        #expect(bad.done.isEmpty && bad.refused.first?.reason.contains("yeniden tara") == true, "\(bad)")
        let ok = await tr.trash(ids: [noted.id], scan: [app, noted], dryRun: true)
        #expect(ok.done.count == 1 && ok.refused.isEmpty, "\(ok)")
        #expect(Trasher.notesInternalCommands(noted.note, ["zeplin"]))
        #expect(!Trasher.notesInternalCommands(noted.note, ["zeplin", "other"]))
        #expect(moved.n == 0)
    }
}

/// Değişebilen süreç listesi (taşıma sırasında uygulama açılması).
private final class MutableProcesses: ProcessListing, @unchecked Sendable {
    private let lock = NSLock()
    private var _list: [RunningProcess] = []
    func set(_ l: [RunningProcess]) { lock.withLock { _list = l } }
    func runningProcesses() -> [RunningProcess] { lock.withLock { _list } }
}

@Suite("Finder: denetim düzeltmeleri (hata + kalkma, yeniden doğrulama, bekleme, -1711/-1744)")
struct FinderAuditFixTests {
    @Test("tek öğe: olay hata döndü ama öğe kalktı: başarı (konum nil)")
    func singleErrorButGone() async throws {
        let t = try TempTree()
        let a = try t.dir("Apps/A.app", in: t.root)
        let bin = try t.dir("Bin", in: t.root)
        let rec = FinderRecycler(timeout: 5, sender: { u, _ in
            try move(u, to: bin)
            throw FinderRecycleError.finderFailed(code: -10000, message: nil)
        })
        let r = await rec.recycle([a])
        if case .success(let loc) = r[a] { #expect(loc == nil) } else { Issue.record("başarı olmalı: \(String(describing: r[a]))") }
        // Kalkmadıysa hata korunur.
        let b = try t.dir("Apps/B.app", in: t.root)
        let keep = FinderRecycler(timeout: 5, sender: { _, _ in throw FinderRecycleError.userCancelled })
        #expect(failure(await keep.recycle([b])[b]) == .userCancelled)
    }

    @Test("yedek: tek öğeli olay iptal döndü ama öğe kalktı: başarı; yedek durmaz")
    func fallbackErrorButGone() async throws {
        let t = try TempTree()
        let a = try t.dir("Apps/A.app", in: t.root)
        let b = try t.dir("Apps/B.app", in: t.root)
        let bin = try t.dir("Bin", in: t.root)
        let singles = Counter()
        let rec = FinderRecycler(timeout: 5, sender: { u, _ in
            singles.hit(u.lastPathComponent)
            try move(u, to: bin)
            throw FinderRecycleError.userCancelled
        }, batchSender: { _, _ in throw FinderRecycleError.finderFailed(code: -10000, message: nil) })
        let r = await rec.recycle([a, b])
        #expect(singles.log == ["A.app", "B.app"], "\(singles.log)")
        #expect(succeeded(r[a]) && succeeded(r[b]))
    }

    @Test("yedekten önce yeniden doğrulama: geçmeyen öğe Finder'a gitmez, ret nedeni korunur")
    func revalidateBeforeFallback() async throws {
        let t = try TempTree()
        let a = try t.dir("Apps/A.app", in: t.root)
        let b = try t.dir("Apps/B.app", in: t.root)
        let bin = try t.dir("Bin", in: t.root)
        let singles = Counter()
        let rec = FinderRecycler(timeout: 5, sender: { u, _ in singles.hit(u.lastPathComponent); try move(u, to: bin); return nil },
                                 batchSender: { _, _ in })
        let r = await rec.recycle([a, b], revalidate: { $0.lastPathComponent == "A.app" ? "çalışıyor" : nil })
        #expect(singles.log == ["B.app"], "\(singles.log)")
        #expect(failure(r[a]) == .revalidationFailed("çalışıyor") && succeeded(r[b]))
        #expect(failure(r[a])?.errorDescription?.contains("çalışıyor") == true)
        #expect(t.exists(a) && !t.exists(b))
    }

    @Test("Trasher: toplu olaydan sonra uygulama açıldıysa yedek olay gönderilmez (appCheck yeniden)")
    func trasherRevalidatesFallback() async throws {
        let t = try TempTree()
        let (apps, basePolicy) = try AppFixture.setup(t)
        var p = basePolicy
        p.writeProbe = AppWriteProbe { _, _ in AppWriteFacts(parentWritable: true, bundleErrno: EPERM, ownerUID: getuid()) }
        let a = try AppFixture.app(t, in: apps, "Aaa", id: "com.example.aaa")
        let b = try AppFixture.app(t, in: apps, "Bbb", id: "com.example.bbb")
        func auth(_ u: URL) -> CleanItem {
            var i = AppFixture.appItem(u)
            i.needsAuthorization = true
            i.preselect = false
            return i
        }
        let items = [auth(a), auth(b)]
        let procs = MutableProcesses()
        let bin = try t.dir("Bin", in: t.root)
        let singles = Counter(), batches = Counter()
        let finder = FinderRecycler(timeout: 5, sender: { u, _ in singles.hit(u.lastPathComponent); try move(u, to: bin); return nil },
                                    batchSender: { _, _ in
                                        batches.hit()
                                        procs.set([RunningProcess(pid: 9, name: "Aaa", path: nil)]) // A açıldı
                                    })
        let tr = Trasher(policy: p, commands: FakeCommands(), processes: procs, selfExecutable: nil, selfBundleID: nil,
                         mover: { _ in Issue.record("normal taşıyıcı kullanılmamalı"); return nil }, privilegedRecycler: finder)
        let r = await tr.trash(items, dryRun: false)
        #expect(batches.n == 1)
        #expect(singles.log == ["Bbb.app"], "\(singles.log)")
        #expect(r.done.map(\.path) == [b.path], "\(r)")
        #expect(r.refused.first { $0.path == a.path }?.reason.contains("çalışıyor") == true, "\(r)")
        #expect(t.exists(a) && !t.exists(b))
    }

    @Test("bekleme: toplu olay geç bitirdiyse yedek olay gönderilmez; bitirmediyse 3 bekleme sonra yedek")
    func settleBeforeFallback() async throws {
        let t = try TempTree()
        let a = try t.dir("Apps/A.app", in: t.root)
        let b = try t.dir("Apps/B.app", in: t.root)
        let bin = try t.dir("Bin", in: t.root)
        let sleeps = Counter()
        let late = FinderRecycler(timeout: 5, sender: { _, _ in Issue.record("yedek gönderilmemeli"); return nil },
                                  batchSender: { _, _ in }, sleeper: { d in
                                      sleeps.hit("\(d)")
                                      if sleeps.n == 2 { try? move(a, to: bin); try? move(b, to: bin) } // geç bitti
                                  })
        let r = await late.recycle([a, b])
        #expect(succeeded(r[a]) && succeeded(r[b]) && sleeps.n == 2, "\(sleeps.log)")
        #expect(sleeps.log.first == "\(FinderRecycler.settleStep)")

        let c = try t.dir("Apps/C.app", in: t.root)
        let d = try t.dir("Apps/D.app", in: t.root)
        let sleeps2 = Counter(), singles = Counter()
        let never = FinderRecycler(timeout: 5, sender: { u, _ in singles.hit(); try move(u, to: bin); return nil },
                                   batchSender: { _, _ in }, sleeper: { _ in sleeps2.hit() })
        let r2 = await never.recycle([c, d])
        #expect(sleeps2.n == FinderRecycler.settlePolls && singles.n == 2)
        #expect(succeeded(r2[c]) && succeeded(r2[d]))
        // Yedek yoksa (iptal) beklenmez.
        let e = try t.dir("Apps/E.app", in: t.root)
        let f = try t.dir("Apps/F.app", in: t.root)
        let sleeps3 = Counter()
        let cancelled = FinderRecycler(timeout: 5, sender: { _, _ in nil },
                                       batchSender: { _, _ in throw FinderRecycleError.userCancelled },
                                       sleeper: { _ in sleeps3.hit() })
        _ = await cancelled.recycle([e, f])
        #expect(sleeps3.n == 0)
    }

    @Test("-1711 ve -1744: ayrı Türkçe metin, yedek yok")
    func waitCancelledAndConsent() async throws {
        #expect(FinderRecycler.mapError(code: -1711, message: "x") == .waitCancelled)
        #expect(FinderRecycler.mapError(code: -1744, message: nil) == .automationConsentRequired)
        #expect(FinderRecycler.mapError(code: -1743, message: nil) == .automationDenied)
        #expect(FinderRecycleError.waitCancelled.code == -1711 && FinderRecycleError.automationConsentRequired.code == -1744)
        #expect(FinderRecycleError.waitCancelled.errorDescription?.contains("iptal edildi") == true)
        #expect(FinderRecycleError.automationConsentRequired.errorDescription?.contains("Otomasyon") == true)
        for err in [FinderRecycleError.waitCancelled, .automationConsentRequired, .revalidationFailed("x")] {
            #expect(!FinderRecycler.fallsBackToSingle(after: err), "\(err)")
            #expect(FinderRecycler.stopsFallback(err))
        }
        let t = try TempTree()
        let a = try t.dir("Apps/A.app", in: t.root)
        let b = try t.dir("Apps/B.app", in: t.root)
        let rec = FinderRecycler(timeout: 5, sender: { _, _ in Issue.record("yedek denenmemeli"); return nil },
                                 batchSender: { _, _ in throw NSError(domain: NSOSStatusErrorDomain, code: -1711) })
        let r = await rec.recycle([a, b])
        #expect(failure(r[a]) == .waitCancelled && failure(r[b]) == .waitCancelled)
    }
}

@Suite("İzin hatası metni: Tam Disk Erişimi yalnız EPERM'de")
struct PermissionTextTests {
    let home = URL(fileURLWithPath: "/Users/biri")
    let box = "/Users/biri/Library/Containers/com.microsoft.Word"

    @Test("EACCES Containers'ta: genel izin metni; EPERM (doğrudan ya da Cocoa altında): Tam Disk Erişimi")
    func eaccesVsEperm() {
        let none: (String) -> Bool = { _ in false }
        let eacces = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let a = Trasher.describe(eacces, path: box, home: home, hasLockFlag: none)
        #expect(a.contains("izin yok") && !a.contains(Trasher.fullDiskAccessMarker))
        let cocoaEperm = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                                 userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        #expect(Trasher.describe(cocoaEperm, path: box, home: home, hasLockFlag: none).contains(Trasher.fullDiskAccessMarker))
        let cocoaBare = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        #expect(!Trasher.describe(cocoaBare, path: box, home: home, hasLockFlag: none).contains(Trasher.fullDiskAccessMarker))
    }

    @Test("kilitli bayrak (öğede ya da üst klasörde): Tam Disk Erişimi yerine kilitli metni")
    func lockedFlag() {
        let eperm = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let onItem = Trasher.describe(eperm, path: box, home: home, hasLockFlag: { $0 == box })
        #expect(onItem.contains("kilitli") && !onItem.contains(Trasher.fullDiskAccessMarker))
        let onParent = Trasher.describe(eperm, path: box, home: home, hasLockFlag: { $0 == "/Users/biri/Library/Containers" })
        #expect(onParent.contains("kilitli"))
        // İzin hatası değilse bayrağa bakılmaz.
        let enoent = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        #expect(!Trasher.describe(enoent, path: box, home: home, hasLockFlag: { _ in true }).contains("kilitli"))
    }

    @Test("hasLockFlag: gerçek uchg bayrağını görür (geçici dosya)")
    func realUchg() throws {
        let t = try TempTree()
        let f = try t.file("kilitli.txt", bytes: 4)
        #expect(!Trasher.hasLockFlag(f.path))
        #expect(chflags(f.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(f.path, 0) }
        #expect(Trasher.hasLockFlag(f.path))
        #expect(!Trasher.hasLockFlag(t.root.appending(path: "yok").path))
    }
}
