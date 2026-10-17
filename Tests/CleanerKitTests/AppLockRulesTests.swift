import Darwin
import Foundation
import Testing
@testable import CleanerKit

/// Uygulama kilit kuralları (karar, 2026-10-17): kilit yalnız çalışan, Cleaner ve yapısal ret; komut satırı
/// bağlantısı ve yakın kullanım uyarıdır. Yalnız geçici klasör ve sahte taşıyıcı.
@Suite("Uygulama kilit kuralları")
struct AppLockRulesTests {
    struct Fixture {
        let t: TempTree
        let policy: PathPolicy
        let apps: URL
        let bin: URL
        let now = Date().addingTimeInterval(400 * 86_400)
    }

    func fixture() throws -> Fixture {
        let t = try TempTree()
        let (apps, policy) = try AppFixture.setup(t)
        let bin = try t.dir("bin", in: t.root)
        return Fixture(t: t, policy: policy, apps: apps, bin: bin)
    }

    func scan(_ f: Fixture, processes: [RunningProcess] = [], opened: [URL: Int] = [:]) async throws -> [CleanItem] {
        var dates: [String: Date] = [:]
        for (u, d) in opened { dates[u.path] = f.now.addingTimeInterval(-Double(d) * 86_400) }
        var ctx = ScanContext.test(f.t, now: f.now, signals: Signals(
            commands: FakeCommands(), processes: PathProcesses(list: processes), spotlight: FakeSpotlight(dates: dates),
            fileDates: LiveFileDates(), git: FakeGit()))
        ctx.pathPolicy = f.policy
        return try await AppsScanner(binDirectories: [f.bin]).scan(ctx)
    }

    @Test("CLI bağlantılı uygulama kırmızı, seçilebilir; artıkları kilitsiz ve en az sarı")
    func cliApp() async throws {
        let f = try fixture()
        let app = try AppFixture.app(f.t, in: f.apps, "Toolbox", id: "com.example.toolbox")
        try FileManager.default.createSymbolicLink(at: f.bin.appending(path: "tbx"),
                                                   withDestinationURL: app.appending(path: "Contents/MacOS/Toolbox"))
        try f.t.dir("Library/Caches/com.example.toolbox")
        try f.t.dir(".toolbox")
        let items = try await scan(f)
        let a = try #require(items.first { !$0.isLeftover })
        #expect(a.risk == .red && !a.isLocked && a.preselect == false && !a.isDefaultSelected)
        #expect(a.note?.contains("Terminaldeki `tbx` komutu bu uygulamaya bağlı; silersen komut çalışmaz") == true)
        let left = items.filter(\.isLeftover)
        #expect(left.count == 2)
        #expect(left.allSatisfy { !$0.isLocked && $0.risk == .yellow && $0.preselect == false }, "\(left)")
    }

    @Test("son N günde açılan sarı, seçilebilir; kesin artığı yeşil, ad tabanlı sarı, kilitsiz")
    func recentApp() async throws {
        let f = try fixture()
        let app = try AppFixture.app(f.t, in: f.apps, "Zeplin", id: "io.zeplin.osx")
        try f.t.dir("Library/Caches/io.zeplin.osx")
        try f.t.dir(".zeplin")
        let items = try await scan(f, opened: [app: 3])
        let a = try #require(items.first { !$0.isLeftover })
        #expect(a.risk == .yellow && !a.isLocked && a.preselect == false && a.dateSignal == .opened(days: 3))
        #expect(a.note?.contains("Son 90 günde açtın; kullanmaya devam ediyorsan silme") == true)
        let left = items.filter(\.isLeftover)
        #expect(left.count == 2 && left.allSatisfy { !$0.isLocked && $0.preselect == false })
        #expect(left.first { $0.leftoverMatch == .bundleID }?.risk == .green)
        #expect(left.first { $0.leftoverMatch == .name }?.risk == .yellow)
    }

    @Test("Spotlight kaydı yok ama yakın kullanım izi: sarı, kilitsiz, mevcut not")
    func activityApp() async throws {
        let f = try fixture()
        try AppFixture.app(f.t, in: f.apps, "Quiet", id: "com.example.quiet")
        let prefs = try f.t.file("Library/Preferences/com.example.quiet.plist", bytes: 100)
        try FileManager.default.setAttributes([.modificationDate: f.now.addingTimeInterval(-2 * 86_400)], ofItemAtPath: prefs.path)
        let items = try await scan(f)
        let a = try #require(items.first { !$0.isLeftover })
        #expect(a.risk == .yellow && !a.isLocked && a.preselect == false)
        #expect(a.note?.contains("Spotlight kaydı yok ama son 2 günde kullanılmış (ayar/önbellek değişti)") == true)
        #expect(items.filter(\.isLeftover).allSatisfy { !$0.isLocked })
    }

    @Test("çalışan uygulama CLI bağlı ve yakında açılmış olsa da kilitli; artıkları da")
    func runningStaysLocked() async throws {
        let f = try fixture()
        let app = try AppFixture.app(f.t, in: f.apps, "Busy", id: "com.example.busy")
        try FileManager.default.createSymbolicLink(at: f.bin.appending(path: "busy"),
                                                   withDestinationURL: app.appending(path: "Contents/MacOS/Busy"))
        try f.t.dir("Library/Caches/com.example.busy")
        let items = try await scan(f, processes: [
            RunningProcess(pid: 7, name: "Busy", path: app.appending(path: "Contents/MacOS/Busy").path),
        ], opened: [app: 1])
        let a = try #require(items.first { !$0.isLeftover })
        #expect(a.isLocked && a.lockReason == "çalışıyor")
        #expect(items.filter(\.isLeftover).allSatisfy { $0.lockReason == "uygulama kilitli: çalışıyor" })
    }

    @Test("yakında açılmış ama yapısal ret (yazılamayan üst klasör) kilitli kalır; artıkları da")
    func structuralStaysLocked() async throws {
        let f = try fixture()
        let app = try AppFixture.app(f.t, in: f.apps, "Stuck", id: "com.example.stuck")
        try f.t.dir("Library/Caches/com.example.stuck")
        chmod(app.path, 0o555)
        defer { chmod(app.path, 0o755) }
        let items = try await scan(f, opened: [app: 1])
        let a = try #require(items.first { !$0.isLeftover })
        #expect(a.isLocked && a.lockReason?.contains("yazma izni") == true, "\(a)")
        #expect(items.filter(\.isLeftover).allSatisfy { $0.lockReason?.hasPrefix("uygulama kilitli") == true })
    }

    @Test("Trasher: CLI bağlı ve yakında açılmış uygulama (sahte) taşınır, artığıyla; çalışan reddedilir")
    func trasherMoves() async throws {
        let f = try fixture()
        let cli = try AppFixture.app(f.t, in: f.apps, "Toolbox", id: "com.example.toolbox")
        try FileManager.default.createSymbolicLink(at: f.bin.appending(path: "tbx"),
                                                   withDestinationURL: cli.appending(path: "Contents/MacOS/Toolbox"))
        let cliCache = try f.t.dir("Library/Caches/com.example.toolbox")
        let recent = try AppFixture.app(f.t, in: f.apps, "Fresh", id: "com.example.fresh")
        let busy = try AppFixture.app(f.t, in: f.apps, "Busy", id: "com.example.busy")
        let scanItems = try await scan(f, opened: [recent: 2])
        #expect(scanItems.filter { !$0.isLeftover }.allSatisfy { !$0.isLocked })

        // Tarama ile taşıma arasında Busy açıldı: taşıma anında reddedilir.
        let moved = Counter()
        let tr = Trasher(policy: f.policy, commands: FakeCommands(), processes: PathProcesses(list: [
            RunningProcess(pid: 9, name: "Busy", path: busy.appending(path: "Contents/MacOS/Busy").path),
        ]), selfExecutable: nil, selfBundleID: nil, mover: try AppFixture.mover(f.t, counter: moved))
        let r = await tr.trash(ids: scanItems.map(\.id), scan: scanItems, dryRun: false)
        #expect(Set(r.done.map(\.path)) == [cli.path, cliCache.path, recent.path], "\(r)")
        #expect(r.refused.map(\.path) == [busy.path] && r.refused.first?.reason == "çalışıyor", "\(r.refused)")
        #expect(!f.t.exists(cli) && !f.t.exists(cliCache) && !f.t.exists(recent) && f.t.exists(busy))
    }
}
