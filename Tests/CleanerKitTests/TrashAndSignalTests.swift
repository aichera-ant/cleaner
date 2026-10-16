import Foundation
import Testing
@testable import CleanerKit

@Suite("Çöp Kutusu")
struct TrasherTests {
    /// Gerçek Çöp Kutusu yerine geçici klasöre taşıyan sahte.
    func tempMover(_ t: TempTree, counter: Counter) throws -> @Sendable (URL) throws -> URL? {
        let bin = try t.dir("FakeTrash", in: t.root)
        return { url in
            counter.hit(url.path)
            let dest = bin.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
    }

    func item(_ url: URL, risk: Risk = .green, lock: String? = nil, method: CleanMethod = .trash) -> CleanItem {
        CleanItem(category: .caches, name: url.lastPathComponent, path: url.path, allocatedBytes: 100,
                  risk: risk, lockReason: lock, method: method)
    }

    @Test("dry-run hiçbir şey taşımaz, komut çalıştırmaz")
    func dryRun() async throws {
        let t = try TempTree()
        let a = try t.file("Library/Caches/A/x.bin")
        let moved = Counter()
        let cmds = FakeCommands()
        let trasher = Trasher(policy: PathPolicy(home: t.home), commands: cmds, mover: try tempMover(t, counter: moved))
        let r = await trasher.trash([item(a.deletingLastPathComponent()), item(t.home.appending(path: ".npm"), method: .command("npm cache clean --force"))])
        #expect(r.dryRun)
        #expect(moved.n == 0 && cmds.counter.n == 0)
        #expect(t.exists(a))
        // .npm yok: dry-run'da bile var olmayan yol reddedilir.
        #expect(r.done.count == 1 && r.refused.count == 1)
    }

    @Test("gerçek taşıma yalnız geçici klasörde, rapor doğru")
    func realMove() async throws {
        let t = try TempTree()
        let a = try t.file("Library/Caches/A/x.bin")
        let dir = a.deletingLastPathComponent()
        let moved = Counter()
        let trasher = Trasher(policy: PathPolicy(home: t.home), commands: FakeCommands(), mover: try tempMover(t, counter: moved))
        let r = await trasher.trash([item(dir)], dryRun: false)
        #expect(!r.dryRun && r.refused.isEmpty)
        #expect(r.done.count == 1 && r.totalBytes == 100)
        #expect(!t.exists(dir))
        let dest = try #require(r.done.first?.detail)
        #expect(dest.contains("cleaner-tests-") && dest.contains("FakeTrash"))
        #expect(moved.log == [dir.path])
    }

    @Test("kilitli, bilgi, yöntemsiz, korunan, ana klasör dışı ve git kökü reddedilir")
    func refusals() async throws {
        let t = try TempTree()
        let ok = try t.dir("Library/Caches/ok")
        let ssh = try t.dir(".ssh")
        let outside = try t.file("dis.bin", in: t.root)
        let repo = try t.dir("Documents/projeler/r")
        try t.dir(".git", in: repo)
        let gitInside = try t.dir("Documents/projeler/r/.git/objects")
        let infoDir = try t.dir("Library/Caches/info")
        var forged = item(try t.dir("Library/Caches/forged"))
        forged.path = ssh.path // id başka yolun id'si
        let items = [
            item(ok, lock: "Chrome çalışıyor"),
            item(infoDir, risk: .info),
            item(t.home.appending(path: "Library/Caches/ok2"), method: .none),
            item(ssh), item(t.home), item(t.home.appending(path: "Documents")),
            item(outside), item(repo), item(gitInside), forged,
        ]
        let moved = Counter()
        let cmds = FakeCommands()
        let trasher = Trasher(policy: PathPolicy(home: t.home), commands: cmds, mover: try tempMover(t, counter: moved))
        let r = await trasher.trash(items, dryRun: false)
        #expect(r.done.isEmpty, "\(r.done)")
        #expect(r.refused.count == items.count, "\(r.refused)")
        #expect(moved.n == 0 && cmds.counter.n == 0)
        for u in [ok, ssh, outside, repo, gitInside] { #expect(t.exists(u)) }
    }

    @Test("komut yöntemi: dry-run'da çalışmaz, gerçek kipte çalışır, hata raporlanır")
    func commandMethod() async throws {
        let t = try TempTree()
        let npm = try t.dir(".npm")
        let cmds = FakeCommands()
        let moved = Counter()
        let trasher = Trasher(policy: PathPolicy(home: t.home), commands: cmds, mover: try tempMover(t, counter: moved))
        let it = item(npm, method: .command("npm cache clean --force"))
        _ = await trasher.trash([it])
        #expect(cmds.counter.n == 0)
        let r = await trasher.trash([it], dryRun: false)
        #expect(cmds.counter.log == ["npm cache clean --force"])
        #expect(r.done.first?.action == .command)
        #expect(moved.n == 0 && t.exists(npm), "komut yöntemli öğe Çöp Kutusu'na taşınmaz")

        let failing = Trasher(policy: PathPolicy(home: t.home),
                              commands: FakeCommands(result: CommandResult(exitCode: 1, stdout: "")),
                              mover: try tempMover(t, counter: moved))
        let f = await failing.trash([it], dryRun: false)
        #expect(f.refused.count == 1 && f.done.isEmpty)
    }
}

@Suite("Sinyaller")
struct SignalTests {
    @Test("komut çalıştırıcı: çıktı, araç yok, zaman aşımı")
    func commandRunner() async throws {
        let r = ProcessCommandRunner()
        let echo = try #require(await r.run("echo", ["merhaba"]))
        #expect(echo.succeeded && echo.stdout == "merhaba\n")
        #expect(await r.run("cleaner-olmayan-arac-xyz", []) == nil)
        let start = Date()
        let slow = try #require(await r.run("sleep", ["10"], timeout: .milliseconds(300)))
        #expect(slow.timedOut && !slow.succeeded)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("süreç listesi: bu test süreci görünür; ad eşleşmesi harf duyarlı")
    func processes() {
        let list = LiveProcessLister().runningProcesses()
        #expect(list.contains { $0.pid == getpid() })
        let fake = FakeProcesses(names: ["claude"])
        #expect(!fake.isRunning("Claude"))
        #expect(fake.isRunning("claude"))
        let app = RunningProcess(pid: 1, name: "Claude Helper", path: "/Applications/Claude.app/Contents/Frameworks/x/Claude Helper")
        struct One: ProcessListing { let p: RunningProcess; func runningProcesses() -> [RunningProcess] { [p] } }
        #expect(One(p: app).isRunning("Claude"))
    }

    @Test("tarih sinyali: açıldı > değişti > bilinmiyor")
    func dateSignal() throws {
        let t = try TempTree()
        let f = try t.file("a.txt")
        let now = Date().addingTimeInterval(10 * 86_400 + 60)
        let opened = Signals.fake(spotlight: FakeSpotlight(dates: [f.path: Date().addingTimeInterval(-86_400)]))
        #expect(opened.dateSignal(for: f, now: now) == .opened(days: 11))
        #expect(Signals.fake().dateSignal(for: f, now: now) == .modified(days: 10))
        #expect(Signals.fake().dateSignal(for: t.home.appending(path: "yok"), now: now) == .unknown)
        #expect(LiveSpotlight().lastUsedDate(t.home.appending(path: "yok")) == nil)
    }

    @Test("git bilgisi: remote, ilk commit, kirli, push edilmemiş")
    func gitInfo() async throws {
        let t = try TempTree()
        let repo = try t.dir("Documents/projeler/r")
        let runner = ProcessCommandRunner(environment: [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
        ])
        func git(_ args: String...) async throws {
            let r = try #require(await runner.run("git", ["-C", repo.path] + args))
            #expect(r.succeeded, "\(args): \(r.stderr)")
        }
        let provider = LiveGitInfo(runner: runner, cloudGuard: CloudGuard(home: t.home))
        #expect(await provider.info(repo: repo) == nil, "depo değil")
        try await git("init", "-q", "-b", "main")
        try t.file("a.txt", bytes: 10, in: repo)
        try await git("add", ".")
        try await git("commit", "-q", "-m", "ilk")
        try await git("remote", "add", "origin", "https://example.invalid/r.git")
        let info = try #require(await provider.info(repo: repo))
        #expect(info.remoteURL == "https://example.invalid/r.git")
        #expect(info.firstCommit?.count == 40)
        #expect(!info.isDirty)
        #expect(info.hasUnpushedCommits, "remote'ta olmayan commit var")
        try t.file("b.txt", bytes: 10, in: repo)
        #expect(try #require(await provider.info(repo: repo)).isDirty)
        // Bulut kökündeki depoya girilmez.
        let cloudRepo = try t.dir("Library/Mobile Documents/com~apple~CloudDocs/r")
        #expect(await provider.info(repo: cloudRepo) == nil)
    }
}
