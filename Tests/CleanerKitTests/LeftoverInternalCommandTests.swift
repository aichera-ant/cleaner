import Foundation
import Testing
@testable import CleanerKit

/// Ad artığının kendi içindeki komut (uygulamanın kendi CLI'ı, ör. `~/.antigravity-ide/antigravity-ide/bin/
/// antigravity-ide`) çakışma sayılmaz: aday kırmızı + not. Dışarıdaki komut çakışmadır. Ret listesi önce gelir.
/// Artık taşımasında süreç listesi her artıkta yeniden okunur. Yalnız geçici klasör; gerçek taşıma yok.

@discardableResult
private func exe(_ t: TempTree, _ rel: String) throws -> URL {
    let u = try t.file(rel, bytes: 16)
    chmod(u.path, 0o755)
    return u
}

private func link(_ t: TempTree, _ rel: String, to dest: URL) throws -> URL {
    let u = t.home.appending(path: rel)
    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: u, withDestinationURL: dest)
    return u
}

private func scan(_ t: TempTree, _ policy: PathPolicy, bin: [URL] = []) async throws -> [CleanItem] {
    var ctx = ScanContext.test(t, now: Date().addingTimeInterval(400 * 86_400), signals: Signals(
        commands: FakeCommands(), processes: PathProcesses(), spotlight: FakeSpotlight(),
        fileDates: LiveFileDates(), git: FakeGit()))
    ctx.pathPolicy = policy
    return try await AppsScanner(binDirectories: bin).scan(ctx)
}

/// Uygulama kökleri aynı, komut klasörleri yeniden okunmuş politika (komut klasörleri kurulurken listelenir).
private func fresh(_ t: TempTree, _ p: PathPolicy) -> PathPolicy { PathPolicy(home: t.home, appRoots: p.appRoots) }

private let note = "İçindeki `zeplin` komutu da silinir; terminalde artık çalışmaz"

@Suite("Ad artığı: kendi içindeki komut")
struct LeftoverInternalCommandScanTests {
    @Test("~/.<x>/bin içindeki sıradan çalıştırılabilir: bağımsız CLI, aday değil (İP3 kararı)")
    func ownBinInside() async throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
        let dot = try t.dir(".zeplin")
        try exe(t, ".zeplin/bin/zeplin")
        let items = try await scan(t, fresh(t, p))
        #expect(!items.contains { $0.path == dot.path })
    }

    @Test("~/.<x>/bin içindeki kendi komutu uygulama paketine bağlantı: aday kırmızı, seçili değil, notlu")
    func ownBinLinkedToApp() async throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        let app = try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
        let dot = try t.dir(".zeplin")
        try link(t, ".zeplin/bin/zeplin", to: app.appending(path: "Contents/MacOS/Zeplin"))
        let items = try await scan(t, fresh(t, p))
        let i = try #require(items.first { $0.path == dot.path }, "aday olmalı")
        #expect(i.risk == .red && i.preselect == false && !i.isDefaultSelected)
        #expect(i.note?.hasPrefix(note) == true, "\(i.note ?? "")")
    }

    @Test("Antigravity düzeni: aday içindeki bağlantı sahip uygulamanın paketine gidiyor (PATH'te iç klasör)")
    func antigravityLayout() async throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        let app = try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
        let dot = try t.dir(".zeplin")
        let l = try link(t, ".zeplin/zeplin/bin/zeplin", to: app.appending(path: "Contents/MacOS/Zeplin"))
        let items = try await scan(t, p, bin: [l.deletingLastPathComponent()])
        let i = try #require(items.first { $0.path == dot.path }, "aday olmalı")
        #expect(i.risk == .red && i.note?.hasPrefix(note) == true)
    }

    @Test("dışarıdan içeriye bağlantı (~/.local/bin/zeplin → ~/.zeplin/...): aday, kırmızı")
    func outsideLinkToInside() async throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
        let dot = try t.dir(".zeplin")
        let real = try exe(t, ".zeplin/versions/1/zeplin")
        try link(t, ".local/bin/zeplin", to: real)
        let i = try #require(try await scan(t, p).first { $0.path == dot.path })
        #expect(i.risk == .red && i.note?.hasPrefix(note) == true)
    }

    @Test("içeriden dışarıya bağlantı, dışarıdaki komut ya da iç+dış karışık: çakışma, aday değil")
    func outsideConflicts() async throws {
        // İçeriden dışarıya (sahip uygulamanın paketi değil).
        do {
            let t = try TempTree()
            let (apps, p) = try AppFixture.setup(t)
            try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
            let dot = try t.dir(".zeplin")
            let out = try exe(t, ".local/share/zeplin/zeplin")
            try link(t, ".zeplin/bin/zeplin", to: out)
            #expect(!(try await scan(t, fresh(t, p))).contains { $0.path == dot.path })
        }
        // Dışarıdaki komut (~/.local/bin → ~/.local/share).
        do {
            let t = try TempTree()
            let (apps, p) = try AppFixture.setup(t)
            try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
            let dot = try t.dir(".zeplin")
            try link(t, ".local/bin/zeplin", to: try exe(t, ".local/share/zeplin/2.0/zeplin"))
            #expect(!(try await scan(t, p)).contains { $0.path == dot.path })
        }
        // Aynı adlı biri içeride, biri dışarıda.
        do {
            let t = try TempTree()
            let (apps, p) = try AppFixture.setup(t)
            try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
            let dot = try t.dir(".zeplin")
            try exe(t, ".zeplin/bin/zeplin")
            try exe(t, ".local/bin/zeplin")
            #expect(!(try await scan(t, fresh(t, p))).contains { $0.path == dot.path })
        }
        // Kırık bağlantı dışarıda: komut sayılır, çakışma.
        do {
            let t = try TempTree()
            let (apps, p) = try AppFixture.setup(t)
            try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
            let dot = try t.dir(".zeplin")
            try link(t, ".local/bin/zeplin", to: t.root.appending(path: "yok"))
            #expect(!(try await scan(t, p)).contains { $0.path == dot.path })
        }
    }

    @Test("ret listesi önce: ~/.claude içindeki komut, ~/.copilot ve ~/.agents aday değil")
    func denyFirst() async throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        try AppFixture.app(t, in: apps, "Claude", id: "com.anthropic.claudefordesktop")
        try AppFixture.app(t, in: apps, "Copilot", id: "x.copilot")
        try AppFixture.app(t, in: apps, "Agents", id: "x.agents")
        let claude = try t.dir(".claude")
        try exe(t, ".claude/bin/claude")
        let others = [try t.dir(".copilot"), try t.dir(".agents")]
        let items = try await scan(t, fresh(t, p))
        for u in [claude] + others {
            #expect(!items.contains { $0.path == u.path }, "\(u.path)")
        }
        #expect(LeftoverNames.deniedReason(entry: ".copilot", parent: "") != nil)
        #expect(LeftoverNames.deniedReason(entry: ".AGENTS", parent: "") != nil)
        #expect(p.nameLeftoverRejectionReason(for: claude, key: "claude") != nil)
    }

    @Test("komut klasörleri: ~/.railway/bin ve doğrudan ~/.<x>/bin (en çok 64); daha derin değil")
    func dotBinDirectories() throws {
        let t = try TempTree()
        try t.dir(".railway/bin")
        try t.dir(".foo/bin")
        try t.dir(".bar/sub/bin")
        try t.dir("plain/bin")
        try t.file(".file")
        let dirs = Set(PathPolicy.defaultCommandDirectories(home: t.home, includeSystem: false).map(\.path))
        #expect(dirs.contains(t.home.appending(path: ".railway/bin").path))
        #expect(dirs.contains(t.home.appending(path: ".foo/bin").path))
        #expect(!dirs.contains(t.home.appending(path: ".bar/sub/bin").path))
        #expect(!dirs.contains(t.home.appending(path: "plain/bin").path))
        for n in 0..<70 { try t.dir(String(format: ".z%02d/bin", n)) }
        #expect(PathPolicy.homeDotBinDirectories(home: t.home).count == 64)
    }

    @Test("komut kataloğu yerleri: bağlantının yeri ve çözülmüş hedefi; kırık bağlantıda hedef yok")
    func catalogLocations() throws {
        let t = try TempTree()
        let real = try exe(t, ".zeplin/app/zeplin")
        let bin = t.home.appending(path: ".local/bin")
        try link(t, ".local/bin/zeplin", to: real)
        try link(t, ".local/bin/broken", to: t.root.appending(path: "yok"))
        let c = InstalledApps.commandCatalog(in: [bin])
        let z = try #require(c["zeplin"]?.first)
        #expect(z.targetKey == PathUtil.key(PathUtil.realPath(real.path) ?? ""))
        #expect(z.entryKey.hasSuffix("/.local/bin/zeplin"))
        #expect(c["broken"]?.first?.targetKey == nil)
    }
}

/// İlk `quietCalls` çağrıda boş, sonra `Zeplin` çalışıyor.
final class OpensLaterProcesses: ProcessListing, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    let quietCalls: Int
    let bundle: URL
    init(quietCalls: Int, bundle: URL) { self.quietCalls = quietCalls; self.bundle = bundle }
    var calls: Int { lock.withLock { n } }
    func runningProcesses() -> [RunningProcess] {
        let c = lock.withLock { n += 1; return n }
        guard c > quietCalls else { return [] }
        return [RunningProcess(pid: 4242, name: "Zeplin", path: bundle.appending(path: "Contents/MacOS/Zeplin").path)]
    }
}

@Suite("Ad artığı: kendi içindeki komut, taşıma anı")
struct LeftoverInternalCommandTrashTests {
    func trasher(_ p: PathPolicy, _ t: TempTree, _ moved: Counter, processes: any ProcessListing = PathProcesses()) throws -> Trasher {
        Trasher(policy: p, commands: FakeCommands(), processes: processes, selfExecutable: nil, selfBundleID: nil,
                mover: try AppFixture.mover(t, counter: moved))
    }

    func named(_ u: URL, _ app: CleanItem, red: Bool) -> CleanItem {
        var i = AppFixture.leftover(u, app: app, bundleID: "io.zeplin.osx", match: .name, key: "zeplin")
        if red {
            // Taramanın kırmızı iç komut öğesine yazdığı not (taşıma anında aranır).
            i.risk = .red
            i.note = AppsScanner.internalCommandNote(["zeplin"])
        }
        return i
    }

    @Test("kırmızı tarama öğesi taşınır; içinde komut varken sarı öğe ve sonradan dışarıya kurulan komut reddedilir")
    func moveTime() async throws {
        let t = try TempTree()
        let (apps, p0) = try AppFixture.setup(t)
        let appURL = try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
        let app = AppFixture.appItem(appURL)
        // Uygulamanın kendi CLI'ı (paket içine bağlantı); sıradan çalıştırılabilir bağımsız CLI sayılırdı.
        try link(t, ".zeplin/bin/zeplin", to: appURL.appending(path: "Contents/MacOS/Zeplin"))
        let p = fresh(t, p0)
        let moved = Counter()
        let dot = t.home.appending(path: ".zeplin")
        let red = named(dot, app, red: true), yellow = named(dot, app, red: false)
        let tr = try trasher(p, t, moved)
        let ok = await tr.trash(ids: [red.id], scan: [app, red], dryRun: true)
        #expect(ok.done.count == 1 && ok.refused.isEmpty, "\(ok)")
        let bad = await tr.trash(ids: [yellow.id], scan: [app, yellow], dryRun: true)
        #expect(bad.done.isEmpty && bad.refused.first?.reason.contains("yeniden tara") == true, "\(bad)")
        // Taramadan sonra dışarıda aynı adlı komut kuruldu: çakışma.
        try exe(t, ".local/bin/zeplin")
        let later = await tr.trash(ids: [red.id], scan: [app, red], dryRun: false)
        #expect(later.done.isEmpty && later.refused.first?.reason.contains("komut satırı aracı `zeplin`") == true, "\(later)")
        #expect(moved.n == 0 && t.exists(dot))
    }

    @Test("uygulama ve kendi CLI'ını içeren artık birlikte: paket önce taşınır (bağlantı kırılır), artık da taşınır")
    func appThenLeftover() async throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        let appURL = try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
        let app = AppFixture.appItem(appURL)
        let l = try link(t, ".zeplin/zeplin/bin/zeplin", to: appURL.appending(path: "Contents/MacOS/Zeplin"))
        let policy = PathPolicy(home: t.home, appRoots: p.appRoots,
                                commandDirectories: [l.deletingLastPathComponent()])
        let dot = t.home.appending(path: ".zeplin")
        let left = named(dot, app, red: true)
        let moved = Counter()
        let r = await (try trasher(policy, t, moved)).trash(ids: [app.id, left.id], scan: [app, left], dryRun: false)
        #expect(r.done.count == 2 && r.refused.isEmpty, "\(r)")
        #expect(!t.exists(dot) && !t.exists(appURL))
    }

    @Test("artık taşıması sırasında uygulama açılırsa kalan artıklar reddedilir (süreç listesi her artıkta)")
    func appOpensMidRun() async throws {
        let t = try TempTree()
        let (apps, p) = try AppFixture.setup(t)
        let appURL = try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
        let app = AppFixture.appItem(appURL)
        let ls = [try t.dir("Library/Application Support/Zeplin"), try t.dir("Library/Caches/Zeplin"),
                  try t.dir("Library/Logs/Zeplin")].map { named($0, app, red: false) }
        let procs = OpensLaterProcesses(quietCalls: 1, bundle: appURL)
        let moved = Counter()
        let r = await (try trasher(p, t, moved, processes: procs)).trash(ids: ls.map(\.id), scan: [app] + ls, dryRun: false)
        #expect(r.done.count == 1 && moved.n == 1, "\(r)")
        #expect(r.refused.count == 2 && r.refused.allSatisfy { $0.reason.contains("çalışıyor") }, "\(r)")
        #expect(procs.calls == 3)
    }
}
