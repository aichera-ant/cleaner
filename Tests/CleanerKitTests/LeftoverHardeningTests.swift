import Foundation
import Testing
@testable import CleanerKit

/// Ad tabanlı artık sıkılaştırması: komut satırı aracı çakışması, sabit ret listesi, önek yalnız klasör, kimlik
/// bilgisi sözcükleri, git deposu, çalıştırılabilir adın aramada kullanılmaması, taşıma anı yeniden doğrulama,
/// çalıştırma başına tek okuma, Finder toplu hata raporu. Yalnız geçici klasör; gerçek taşıma ve Apple Event yok.

private func writeInfo(_ bundle: URL, _ plist: [String: Any]) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: bundle.appending(path: "Contents/Info.plist"))
}

/// Çalıştırma biti olan (ya da olmayan) sahte komut.
@discardableResult
private func command(_ t: TempTree, _ rel: String, executable: Bool = true) throws -> URL {
    let u = try t.file(rel, bytes: 16)
    chmod(u.path, executable ? 0o755 : 0o644)
    return u
}

private func scan(_ t: TempTree, _ policy: PathPolicy, bin: [URL] = []) async throws -> [CleanItem] {
    var ctx = ScanContext.test(t, now: Date().addingTimeInterval(400 * 86_400), signals: Signals(
        commands: FakeCommands(), processes: PathProcesses(), spotlight: FakeSpotlight(),
        fileDates: LiveFileDates(), git: FakeGit()))
    ctx.pathPolicy = policy
    return try await AppsScanner(binDirectories: bin).scan(ctx)
}

private func namePaths(_ items: [CleanItem]) -> Set<String> {
    Set(items.filter { $0.leftoverMatch == .name }.map(\.path))
}

/// `runningProcesses()` çağrılarını sayar.
final class CountingProcesses: ProcessListing, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var calls: Int { lock.withLock { n } }
    func runningProcesses() -> [RunningProcess] { lock.withLock { n += 1 }; return [] }
}

@Suite("Ad artığı sıkılaştırma: kurallar")
struct LeftoverHardeningRuleTests {
    @Test("sabit ret listesi ve önekleri ana klasörde; büyük/küçük harf duyarsız; ~/Library etkilenmez")
    func denyList() {
        for e in [".claude", ".CLAUDE", ".codex", ".gemini", ".cursor", ".opencode", ".config", ".local", ".cache",
                  ".kube", ".aws", ".docker", ".npm", ".cargo", ".vscode", ".ssh", ".gnupg", ".gitconfig",
                  ".git-credentials", ".github", ".zshrc", ".zsh_history", ".bash_profile", ".bashrc", ".profile",
                  ".netrc", ".env", ".env.local", ".oh-my-zsh", ".nvm", ".terraform.d", ".cloudflared", ".wrangler",
                  ".supabase", ".vercel", ".expo", ".cocoapods", ".swiftpm", ".claude-code", ".cursor-server"] {
            #expect(LeftoverNames.deniedReason(entry: e, parent: "") != nil, "\(e)")
        }
        // Kimlik bilgisi sözcükleri (ana klasör).
        for e in [".zeplin-token", ".zeplin_secret", ".zeplinkey", ".zeplin-credentials", ".zeplin-password",
                  ".zeplin-auth", ".zeplin.env", ".ZEPLIN-TOKEN"] {
            #expect(LeftoverNames.deniedReason(entry: e, parent: "") != nil, "\(e)")
        }
        for e in [".zeplin", ".zeplin-cache", ".antigravity", ".warp", ".anydesk"] {
            #expect(LeftoverNames.deniedReason(entry: e, parent: "") == nil, "\(e)")
        }
        // ~/Library altındaki uygulama klasörü adı bu listeden etkilenmez.
        #expect(LeftoverNames.deniedReason(entry: "Claude", parent: "Library/Application Support") == nil)
        #expect(LeftoverNames.deniedReason(entry: "Keybase", parent: "Library/Application Support") == nil)
    }

    @Test("çalıştırılabilir ad aramada yok, çakışmada var; genel adlar genişletildi")
    func executableNotSearched() {
        let warp = AppBundleInfo(bundleID: "dev.warp.Warp-Stable", name: "Warp", version: nil, isAppStore: false,
                                 uninstallerHints: [], bundleName: "Warp", executableName: "stable")
        #expect(warp.leftoverNameKeys == ["warp"])
        #expect(warp.allNameKeys.contains("stable"))
        let other = AppBundleInfo(bundleID: "x.y", name: "Foo Bar", version: nil, isAppStore: false,
                                  uninstallerHints: [], executableName: "Zebrafish")
        #expect(!other.leftoverNameKeys.contains("zebrafish") && other.allNameKeys.contains("zebrafish"))
        for g in ["stable", "applet", "droplet", "launcher", "main", "run", "start", "app", "electron"] {
            #expect(!LeftoverNames.isUsableKey(g), "\(g)")
        }
    }

    @Test("komut adı kataloğu: bağlantı ve çalıştırma bitli dosya; çalıştırılamayan dosya, klasör, gizli değil")
    func commandCatalog() throws {
        let t = try TempTree()
        let bin = try t.dir("cli", in: t.root)
        try command(t, "../cli/Zeplin-CLI")
        try command(t, "../cli/plain.txt", executable: false)
        try t.dir("folder", in: bin)
        try command(t, "../cli/.hidden")
        try FileManager.default.createSymbolicLink(at: bin.appending(path: "claude"),
                                                   withDestinationURL: t.root.appending(path: "yok"))
        let names = InstalledApps.commandNames(in: [bin, t.root.appending(path: "yok-klasor")])
        #expect(names == ["zeplincli", "claude"], "\(names)")
    }

    @Test("varsayılan komut klasörleri: test kipinde yalnız ana klasör (nvm/fnm sürümleri dahil), gerçekte PATH de")
    func defaultDirectories() throws {
        let t = try TempTree()
        try t.dir(".nvm/versions/node/v22.1.0/bin")
        try t.dir("Library/Application Support/fnm/node-versions/v20.0.0/installation/bin")
        let test = PathPolicy.defaultCommandDirectories(home: t.home, includeSystem: false).map(\.path)
        #expect(test.allSatisfy { $0.hasPrefix(t.home.path) })
        #expect(test.contains(t.home.appending(path: ".local/bin").path))
        #expect(test.contains(t.home.appending(path: ".nvm/versions/node/v22.1.0/bin").path))
        #expect(test.contains(t.home.appending(path: "Library/Application Support/fnm/node-versions/v20.0.0/installation/bin").path))
        let live = PathPolicy.defaultCommandDirectories(home: t.home, includeSystem: true).map(\.path)
        for p in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] { #expect(live.contains(p), "\(p)") }
        let p = PathPolicy(home: t.home, appRoots: [])
        #expect(p.commandDirectories.allSatisfy { $0.path.hasPrefix(t.home.path) })
    }
}

@Suite("Ad artığı sıkılaştırma: tarayıcı")
struct LeftoverHardeningScanTests {
    @Test("Claude: ~/.claude ve ~/.claude-* hiçbir zaman aday değil; ~/Library/Application Support/Claude aday")
    func claudeDenied() async throws {
        let t = try TempTree()
        let (apps, policy) = try AppFixture.setup(t)
        try AppFixture.app(t, in: apps, "Claude", id: "com.anthropic.claudefordesktop")
        let support = try t.dir("Library/Application Support/Claude")
        let denied = [try t.dir(".claude"), try t.dir(".claude-code"), try t.file(".claude.json")]
        let items = try await scan(t, policy)
        let named = namePaths(items)
        #expect(named.contains(support.path))
        // `.claude.json`: temel ad "claude.json" → normalize "claudejson", eşleşmez; `.claude` ve önek ret listesinde.
        for d in denied { #expect(!named.contains(d.path), "\(d.path)") }
        for d in denied { #expect(policy.nameLeftoverRejectionReason(for: d, key: "claude") != nil, "\(d.path)") }
    }

    @Test("komut satırı aracıyla aynı adlı ev girdisi aday değil (ana klasör ve tarayıcıya verilen bin klasörü)")
    func cliConflict() async throws {
        let t = try TempTree()
        let (apps, policy) = try AppFixture.setup(t)
        try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
        try AppFixture.app(t, in: apps, "Notexec", id: "x.notexec")
        try AppFixture.app(t, in: apps, "Gemma", id: "x.gemma")
        try command(t, ".local/bin/zeplin")
        try command(t, ".local/bin/notexec", executable: false)
        try command(t, ".nvm/versions/node/v22.1.0/bin/gemma")
        let zDot = try t.dir(".zeplin"), zPrefix = try t.dir(".zeplin-cache")
        let zSupport = try t.dir("Library/Application Support/Zeplin")
        let nDot = try t.dir(".notexec")
        let gDot = try t.dir(".gemma")
        // nvm sürüm klasörü PathPolicy kurulurken listelenir: politikayı yeniden kur.
        let policy2 = PathPolicy(home: t.home, appRoots: policy.appRoots)
        let named = namePaths(try await scan(t, policy2))
        #expect(!named.contains(zDot.path) && !named.contains(zPrefix.path) && !named.contains(gDot.path), "\(named)")
        #expect(named.contains(zSupport.path), "CLI çakışması yalnız ana klasörde")
        #expect(named.contains(nDot.path), "çalıştırma biti olmayan dosya komut sayılmaz")

        // Tarayıcıya verilen (ana klasör dışı) bin klasörü de katalogdadır.
        let t2 = try TempTree()
        let (apps2, p2) = try AppFixture.setup(t2)
        try AppFixture.app(t2, in: apps2, "Zeplin", id: "io.zeplin.osx")
        let bin = try t2.dir("bin2", in: t2.root)
        try command(t2, "../bin2/zeplin")
        let dot2 = try t2.dir(".zeplin")
        #expect(namePaths(try await scan(t2, p2)).contains(dot2.path))
        #expect(!namePaths(try await scan(t2, p2, bin: [bin])).contains(dot2.path))
    }

    @Test(".<ad>-* öneki yalnız klasörde; kimlik bilgisi sözcüklü girdi aday değil; tam ad dosya olabilir")
    func prefixOnlyDirectories() async throws {
        let t = try TempTree()
        let (apps, policy) = try AppFixture.setup(t)
        try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
        let exactFile = try t.file(".zeplin")
        let prefixDir = try t.dir(".zeplin-cache")
        let prefixFile = try t.file(".zeplin-history")
        let secret = [try t.dir(".zeplin-token"), try t.file(".zeplin-secrets"), try t.dir(".zeplin-env")]
        let named = namePaths(try await scan(t, policy))
        #expect(named.contains(exactFile.path) && named.contains(prefixDir.path), "\(named)")
        #expect(!named.contains(prefixFile.path))
        for s in secret { #expect(!named.contains(s.path), "\(s.path)") }
    }

    @Test("içinde (doğrudan çocuğunda) git deposu olan ad artığı kırmızı, notlu, seçili değil")
    func gitInside() async throws {
        let t = try TempTree()
        let (apps, policy) = try AppFixture.setup(t)
        try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
        let dot = try t.dir(".zeplin")
        try t.dir("dotfiles/.git", in: dot)
        let plain = try t.dir("Library/Application Support/Zeplin")
        try t.dir("cache/sub/.git", in: plain) // yalnız doğrudan çocuğa bakılır
        let items = try await scan(t, policy)
        let gi = try #require(items.first { $0.path == dot.path })
        #expect(gi.risk == .red && gi.preselect == false && !gi.isDefaultSelected)
        #expect(gi.note?.contains("İçinde git deposu var; kişisel ayar/dotfiles olabilir") == true)
        let pi = try #require(items.first { $0.path == plain.path })
        #expect(pi.risk == .yellow && pi.note?.contains("git deposu") == false)
        #expect(LeftoverNames.containsGitRepository(dot) && !LeftoverNames.containsGitRepository(plain))
    }

    @Test("çalıştırılabilir ad (Warp → stable) artık aramasında kullanılmaz")
    func executableNameNotUsed() async throws {
        let t = try TempTree()
        let (apps, policy) = try AppFixture.setup(t)
        let app = try AppFixture.app(t, in: apps, "Foo", id: "x.foo")
        try writeInfo(app, ["CFBundleIdentifier": "x.foo", "CFBundleName": "Foo", "CFBundleExecutable": "Zebrafish"])
        let z = [try t.dir(".zebrafish"), try t.dir("Library/Application Support/Zebrafish")]
        let named = namePaths(try await scan(t, policy))
        for u in z { #expect(!named.contains(u.path), "\(u.path)") }
    }
}

@Suite("Ad artığı sıkılaştırma: taşıma anı")
struct LeftoverHardeningTrashTests {
    func setup() throws -> (TempTree, PathPolicy, CleanItem) {
        let t = try TempTree()
        let (apps, policy) = try AppFixture.setup(t)
        let app = try AppFixture.app(t, in: apps, "Zeplin", id: "io.zeplin.osx")
        return (t, policy, AppFixture.appItem(app))
    }

    func trasher(_ p: PathPolicy, _ t: TempTree, _ moved: Counter, processes: any ProcessListing = PathProcesses()) throws -> Trasher {
        Trasher(policy: p, commands: FakeCommands(), processes: processes, selfExecutable: nil, selfBundleID: nil,
                mover: try AppFixture.mover(t, counter: moved))
    }

    func named(_ u: URL, _ app: CleanItem, key: String = "zeplin") -> CleanItem {
        AppFixture.leftover(u, app: app, bundleID: "io.zeplin.osx", match: .name, key: key)
    }

    @Test("taramadan sonra aynı adlı komut kuruldu: ev girdisi taşınmaz")
    func cliInstalledLater() async throws {
        let (t, p, app) = try setup()
        let l = named(try t.dir(".zeplin"), app)
        try command(t, ".local/bin/zeplin")
        let moved = Counter()
        let r = try await trasher(p, t, moved).trash(ids: [l.id], scan: [app, l], dryRun: false)
        #expect(r.done.isEmpty && r.refused.first?.reason.contains("komut satırı aracı `zeplin`") == true, "\(r)")
        #expect(moved.n == 0 && t.exists(l.url))
    }

    @Test("ret listesi, önekli dosya ve kimlik bilgisi sözcüğü taşıma anında da reddedilir")
    func policyAtMoveTime() async throws {
        let (t, p, app) = try setup()
        let bad = [named(try t.dir(".claude"), app, key: "claude"), named(try t.dir(".zshrc-d"), app, key: "zshrc"),
                   named(try t.file(".zeplin-cfg"), app), named(try t.dir(".zeplin-token"), app)]
        let moved = Counter()
        let tr = try trasher(p, t, moved)
        for b in bad {
            let r = await tr.trash(ids: [b.id], scan: [app, b], dryRun: false)
            #expect(r.done.isEmpty && !r.refused.isEmpty, "\(b.path)")
        }
        #expect(moved.n == 0)
    }

    @Test("kurulu uygulamalar çalıştırma başına bir kez, süreç listesi her artıkta okunur")
    func environmentOncePerRun() async throws {
        let (t, p, app) = try setup()
        let ls = [named(try t.dir(".zeplin"), app), named(try t.dir("Library/Caches/Zeplin"), app),
                  named(try t.dir("Library/Logs/Zeplin"), app)]
        let procs = CountingProcesses()
        let moved = Counter()
        let r = try await trasher(p, t, moved, processes: procs).trash(ids: ls.map(\.id), scan: [app] + ls, dryRun: true)
        #expect(r.done.count == 3 && r.refused.isEmpty, "\(r)")
        #expect(procs.calls == 3)
    }
}

@Suite("Finder toplu hata raporu")
struct FinderBatchPartialTests {
    @Test("olay hata/zaman aşımı dönse de taşınmış yol başarılı, yerinde kalan o hatayla")
    func partialOnError() async throws {
        let t = try TempTree()
        let a = try t.dir("Apps/A.app", in: t.root)
        let b = try t.dir("Apps/B.app", in: t.root)
        let bin = try t.dir("Bin", in: t.root)
        let rec = FinderRecycler(timeout: 5, sender: { _, _ in nil }, batchSender: { urls, _ in
            try FileManager.default.moveItem(at: urls[0], to: bin.appending(path: "A.app"))
            throw FinderRecycleError.timedOut
        })
        let r = await rec.recycle([a, b])
        if case .success(let loc) = try #require(r[a]) { #expect(loc == nil) } else { Issue.record("A taşındı, başarılı olmalı") }
        if case .failure(let e) = try #require(r[b]) { #expect(e as? FinderRecycleError == .timedOut) } else { Issue.record("B yerinde") }
    }
}
