import Darwin
import Foundation
import Testing
@testable import CleanerKit

// İP1 denetim düzeltme turu: komut izin listesi, iç içe öğeler, okunamayan klasör, varsayılan seçim,
// mükerrer grupları, bulut/git, küçük sağlamlaştırmalar. Yalnız geçici klasör ve sahteler.

private func fakeMover(_ t: TempTree, counter: Counter) throws -> @Sendable (URL) throws -> URL? {
    let bin = try t.dir("FakeTrash", in: t.root)
    return { url in
        counter.hit(url.path)
        let dest = bin.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }
}

private func trasher(_ t: TempTree, commands: FakeCommands = FakeCommands(), moved: Counter = Counter()) throws -> Trasher {
    Trasher(policy: PathPolicy(home: t.home), commands: commands, mover: try fakeMover(t, counter: moved))
}

// MARK: 1. Komut izin listesi

@Suite("Komut izin listesi")
struct CommandPolicyTests {
    let uuid = "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"

    @Test("docker öğeleri doğrulanır; kabuksuz, '--' ile ve yoldaki kimlikten kurulan komut çalışır")
    func dockerRuns() async throws {
        let t = try TempTree()
        let cmds = FakeCommands()
        let tr = try trasher(t, commands: cmds)
        let items = [
            CleanItem(category: .docker, name: "img", path: "/docker/image/abc123", allocatedBytes: 10, risk: .yellow,
                      method: .command("docker rmi -- abc123")),
            CleanItem(category: .docker, name: "vol", path: "/docker/volume/my_vol", allocatedBytes: 10, risk: .red,
                      method: .command("docker volume rm -- my_vol")),
            CleanItem(category: .docker, name: "c", path: "/docker/container/cccc2222dddd", allocatedBytes: 10, risk: .yellow,
                      method: .command("docker rm -- cccc2222dddd")),
            CleanItem(category: .docker, name: "bc", path: "/docker/build-cache", allocatedBytes: 10, risk: .green,
                      method: .command("docker builder prune -f")),
        ]
        let dry = await tr.trash(items)
        #expect(dry.refused.isEmpty, "\(dry.refused)")
        #expect(dry.done.count == 4 && cmds.counter.n == 0)
        let real = await tr.trash(items, dryRun: false)
        #expect(real.refused.isEmpty && real.done.count == 4)
        #expect(Set(cmds.counter.log) == [
            "docker rmi -- abc123", "docker volume rm -- my_vol", "docker rm -- cccc2222dddd", "docker builder prune -f",
        ])
    }

    @Test("kötüye kullanım: uydurma komut, kimlik, yol, kategori ve Çöp Kutusu yöntemi reddedilir")
    func dockerAbuse() async throws {
        let t = try TempTree()
        let cmds = FakeCommands()
        let tr = try trasher(t, commands: cmds)
        func d(_ path: String, _ cmd: String?, category: CleanerKit.Category = .docker) -> CleanItem {
            CleanItem(category: category, name: "x", path: path, allocatedBytes: 1, risk: .yellow,
                      method: cmd.map { .command($0) } ?? .trash)
        }
        let items = [
            d("/docker/image/abc123", "docker rmi -- abc123; rm -rf ~"),
            d("/docker/image/abc123", "docker rmi -- def456"),
            d("/docker/image/xyz", "docker rmi -- xyz"), // onaltılık değil
            d("/docker/volume/-rf", "docker volume rm -- -rf"),
            d("/docker/volume/völ", "docker volume rm -- völ"),
            d("/docker/other/abc", "docker rm -- abc"),
            d("/docker/container/abc/def", "docker rm -- abc"),
            d("/docker/image/abc123", "docker rmi -- abc123", category: .caches),
            d("/docker/image/abc123", nil), // Çöp Kutusu yöntemi
            d("/docker/build-cache", "docker builder prune -af"),
        ]
        for item in items {
            let r = await tr.trash([item], dryRun: false)
            #expect(r.done.isEmpty && r.refused.count == 1, "\(item.path) \(item.method)")
        }
        #expect(cmds.counter.n == 0)
    }

    @Test("simülatör: UDID UUID, yol CoreSimulator/Devices altında, komut birebir")
    func simulator() async throws {
        let t = try TempTree()
        let dev = try t.dir("Library/Developer/CoreSimulator/Devices/\(uuid)")
        let other = try t.dir("Library/Caches/\(uuid)")
        let cmds = FakeCommands()
        let tr = try trasher(t, commands: cmds)
        func s(_ url: URL, _ cmd: String) -> CleanItem {
            CleanItem(category: .xcode, name: "sim", path: url.path, allocatedBytes: 5, risk: .green, method: .command(cmd))
        }
        let good = s(dev, "xcrun simctl delete \(uuid)")
        let r = await tr.trash([good], dryRun: false)
        #expect(r.refused.isEmpty && cmds.counter.log == ["xcrun simctl delete \(uuid)"])
        let bad = await tr.trash([
            s(other, "xcrun simctl delete \(uuid)"),
            s(t.home.appending(path: "Library/Developer/CoreSimulator/Devices/not-a-uuid"), "xcrun simctl delete not-a-uuid"),
        ], dryRun: false)
        #expect(bad.done.isEmpty && bad.refused.count == 2)
        let mismatch = s(dev, "xcrun simctl delete all")
        #expect(tr.rejectionReason(for: mismatch) != nil)
        #expect(cmds.counter.n == 1)
    }

    @Test("kural komutları kural id'sine ve yoluna bağlı; brew artık komut değil")
    func ruleCommands() async throws {
        let t = try TempTree()
        let npm = try t.dir(".npm")
        let other = try t.dir("Library/Caches/x")
        let cmds = FakeCommands()
        let tr = try trasher(t, commands: cmds)
        func c(_ url: URL, _ cmd: String) -> CleanItem {
            CleanItem(category: .caches, name: "n", path: url.path, allocatedBytes: 5, risk: .green, method: .command(cmd))
        }
        let r = await tr.trash([c(npm, "npm cache clean --force")], dryRun: false)
        #expect(r.refused.isEmpty && cmds.counter.log == ["npm cache clean --force"])
        let bad = await tr.trash([c(other, "npm cache clean --force"), c(npm, "brew cleanup -s")], dryRun: false)
        #expect(bad.done.isEmpty && bad.refused.count == 2)
        #expect(cmds.counter.n == 1)

        // Kural dosyası izin listesinde olmayan komut taşıyamaz.
        func set(_ id: String, _ path: String, _ cmd: String) -> RuleSet {
            RuleSet(version: 1, rules: [Rule(id: id, path: path, category: .caches, risk: .green, name: "x",
                                             description: "x", method: .command(cmd))])
        }
        #expect(throws: RuleSet.LoadError.self) { try set("npm-cache", "~/.npm", "rm -rf ~").validate() }
        #expect(throws: RuleSet.LoadError.self) { try set("baska", "~/.npm", "npm cache clean --force").validate() }
        #expect(throws: RuleSet.LoadError.self) { try set("npm-cache", "~/Library", "npm cache clean --force").validate() }
        try set("npm-cache", "~/.npm", "npm cache clean --force").validate()
        let bundled = try RuleSet.loadBundled()
        #expect(bundled.rules.first { $0.id == "homebrew-cache" }?.method == .trash)
    }

    @Test("güvenli kimlik: yalnız ASCII, harf/rakamla başlar")
    func safeToken() {
        for ok in ["abc", "A1", "0f-1.2_x", "sahipsiz_vol"] { #expect(XcodeScanner.isSafeToken(ok), "\(ok)") }
        for bad in ["", "-rf", ".x", "_x", "ı1", "é", "a b", "a;b", "١٢٣", "a/b"] {
            #expect(!XcodeScanner.isSafeToken(bad), "\(bad)")
        }
        #expect(CommandPolicy.isUUID(uuid) && !CommandPolicy.isUUID("0F1E2D3C-4B5A-6978-8796"))
    }
}

// MARK: 2. Tarama motoru: birleştirme, iç içe öğeler

@Suite("Tarama motoru: iç içe öğeler")
struct NestingTests {
    func engine(_ cleaners: [any Cleaner]) -> ScanEngine {
        var r = CleanerRegistry()
        for c in cleaners { r.register(c) }
        return ScanEngine(registry: r)
    }

    @Test("aynı yol: en kısıtlayıcı kazanır, kayıt sırası değil")
    func mostRestrictive() async throws {
        let t = try TempTree()
        let h = t.home.path
        let a = FakeCleaner(id: "a", categories: [.caches], items: [
            CleanItem(category: .caches, name: "a-yeşil", path: h + "/Library/Caches/x", allocatedBytes: 1, risk: .green),
            CleanItem(category: .caches, name: "a-sarı", path: h + "/Library/Caches/y", allocatedBytes: 1, risk: .yellow),
            CleanItem(category: .caches, name: "a-kırmızı", path: h + "/Library/Caches/z", allocatedBytes: 1, risk: .red),
        ])
        let b = FakeCleaner(id: "b", categories: [.caches], items: [
            CleanItem(category: .caches, name: "b-kilitli", path: h + "/Library/Caches/x", allocatedBytes: 1, risk: .green,
                      lockReason: "çalışıyor"),
            CleanItem(category: .caches, name: "b-kırmızı", path: h + "/Library/Caches/y", allocatedBytes: 1, risk: .red),
            CleanItem(category: .caches, name: "b-bilgi", path: h + "/Library/Caches/z", allocatedBytes: 1, risk: .info,
                      method: .none),
        ])
        let names = Set(try await engine([a, b]).scan(.test(t)).items.map(\.name))
        #expect(names == ["b-kilitli", "b-kırmızı", "b-bilgi"])
    }

    @Test("alt ağacında kilitli ya da tutulacak öğe olan üst öğe kilitlenir; Trasher da reddeder")
    func lockPropagation() async throws {
        let t = try TempTree()
        let outer = try t.dir("Library/Caches/Outer")
        let inner = try t.dir("Library/Caches/Outer/Inner")
        let box = try t.dir("kutu")
        let keeper = try t.file("kutu/belge.pdf")
        let a = FakeCleaner(id: "a", categories: [.caches], items: [
            CleanItem(category: .caches, name: "outer", path: outer.path, allocatedBytes: 100, risk: .green),
            CleanItem(category: .caches, name: "inner", path: inner.path, allocatedBytes: 10, risk: .green, lockReason: "çalışıyor"),
        ])
        let b = FakeCleaner(id: "b", categories: [.largeOld, .duplicates], items: [
            CleanItem(category: .largeOld, name: "kutu", path: box.path, allocatedBytes: 100, risk: .red),
            CleanItem(category: .duplicates, name: "belge", path: keeper.path, allocatedBytes: 0, risk: .info,
                      method: .none, groupID: "g", keeperPath: keeper.path),
        ])
        let report = try await engine([a, b]).scan(.test(t))
        let by = Dictionary(uniqueKeysWithValues: report.items.map { ($0.name, $0) })
        #expect(by["outer"]?.isLocked == true)
        #expect(by["outer"]?.lockReason?.hasPrefix("İçinde kullanımdaki öğe var") == true)
        #expect(by["inner"]?.isLocked == true)
        // largeOld (genel) kapsayan klasör, daha özel kategorinin öğesini kapsadığı için atılır.
        #expect(by["kutu"] == nil && by["belge"] != nil)

        // Trasher: kilitsiz bir kopyası verilse bile tarama öğeleriyle reddedilir.
        let unlocked = CleanItem(category: .caches, name: "outer", path: outer.path, allocatedBytes: 100, risk: .green)
        let moved = Counter()
        let tr = try trasher(t, moved: moved)
        let r = await tr.trash([unlocked], dryRun: false, scanItems: report.items)
        #expect(r.done.isEmpty && r.refused.first?.reason == "öğe tarama sonucundan farklı")
        // Tarama öğesinin kendisi (id ile) de kilitli olduğu için reddedilir.
        let byID = await tr.trash(ids: [unlocked.id], scan: report.items, dryRun: false)
        #expect(byID.done.isEmpty && byID.refused.first?.reason.hasPrefix("kilitli") == true)
        let boxItem = CleanItem(category: .largeOld, name: "kutu", path: box.path, allocatedBytes: 100, risk: .red)
        let r2 = await tr.trash([boxItem], dryRun: false, scanItems: report.items)
        #expect(r2.done.isEmpty && r2.refused.count == 1)
        #expect(moved.n == 0 && t.exists(outer) && t.exists(keeper))
    }

    @Test("çift sayım: daha özel kategori kazanır; aynı özgüllükte üst öğe kapsar")
    func doubleCounting() async throws {
        let t = try TempTree()
        let h = t.home.path
        let a = FakeCleaner(id: "a", categories: [.oldVersions, .caches], items: [
            CleanItem(category: .oldVersions, name: "claude-1", path: h + "/.local/share/claude/versions/1.0", allocatedBytes: 50, risk: .green),
            CleanItem(category: .caches, name: "üst", path: h + "/Library/Caches/U", allocatedBytes: 100, risk: .green),
            CleanItem(category: .caches, name: "alt", path: h + "/Library/Caches/U/A", allocatedBytes: 40, risk: .green),
        ])
        let b = FakeCleaner(id: "b", categories: [.largeOld], items: [
            CleanItem(category: .largeOld, name: ".local", path: h + "/.local", allocatedBytes: 500, risk: .red),
            CleanItem(category: .largeOld, name: "büyük dosya", path: h + "/Library/Caches/U/b.bin", allocatedBytes: 60, risk: .red),
        ])
        let report = try await engine([a, b]).scan(.test(t))
        #expect(Set(report.items.map(\.name)) == ["claude-1", "üst"])
        #expect(report.items.reduce(0) { $0 + $1.allocatedBytes } == 150)
    }

    @Test("kapsayan taşınamıyorsa (kilitli) aynı özgüllükteki içerideki temizlenebilir öğe kalır")
    func lockedOuterKeepsInner() async throws {
        let t = try TempTree()
        let h = t.home.path
        let a = FakeCleaner(id: "a", categories: [.caches], items: [
            CleanItem(category: .caches, name: "üst", path: h + "/Library/Caches/U", allocatedBytes: 100, risk: .green),
            CleanItem(category: .caches, name: "kilitli", path: h + "/Library/Caches/U/K", allocatedBytes: 10, risk: .green, lockReason: "x"),
            CleanItem(category: .caches, name: "temiz", path: h + "/Library/Caches/U/T", allocatedBytes: 10, risk: .green),
        ])
        let items = try await engine([a]).scan(.test(t)).items
        #expect(Set(items.map(\.name)) == ["üst", "kilitli", "temiz"])
        #expect(items.first { $0.name == "temiz" }?.isDefaultSelected == true)
    }

    @Test("büyük ve eski: başka tarayıcının öğesini kapsayan klasörü aday yapmaz, kalan büyük dosyayı ayrı verir")
    func largeOldClaimed() async throws {
        let t = try TempTree()
        try t.file(".local/share/claude/versions/1.0/claude", bytes: 64 * 1024)
        try t.file(".local/share/claude/versions/2.0/claude", bytes: 64 * 1024)
        let big = try t.file(".local/diger/buyuk.bin", bytes: 64 * 1024)
        let h = t.home.path
        let versions = FakeCleaner(id: "ov", categories: [.oldVersions], items: [
            CleanItem(category: .oldVersions, name: "c1", path: h + "/.local/share/claude/versions/1.0", allocatedBytes: 1, risk: .green),
            CleanItem(category: .oldVersions, name: "c2", path: h + "/.local/share/claude/versions/2.0", allocatedBytes: 1, risk: .green,
                      lockReason: "en yüksek sürüm"),
        ])
        let lo = LargeOldScanner(minFileBytes: 32 * 1024, folderCandidateBytes: 100 * 1024)
        // Karşılaştırma: tek başına çalışırsa .local klasörünü aday yapar.
        let alone = try await lo.scan(.test(t))
        #expect(alone.contains { $0.path.hasSuffix("/.local") })
        let report = try await engine([lo, versions]).scan(.test(t))
        let paths = report.items.map(\.path)
        #expect(!paths.contains { $0.hasSuffix("/.local") || $0.hasSuffix("/.local/share") || $0.hasSuffix("/claude") })
        #expect(paths.contains { $0.hasSuffix(big.path.components(separatedBy: "/home/").last!) })
        #expect(report.items.filter { $0.category == .largeOld }.count == 1)
    }

    @Test("aynı çalıştırmada üst ve alt öğe: alt öğe atlanır, iki kez sayılmaz, ret değildir")
    func parentAndChild() async throws {
        let t = try TempTree()
        let parent = try t.dir("Library/Caches/P")
        let child = try t.file("Library/Caches/P/c/x.bin").deletingLastPathComponent()
        let p = CleanItem(category: .caches, name: "p", path: parent.path, allocatedBytes: 100, risk: .green)
        let c = CleanItem(category: .caches, name: "c", path: child.path, allocatedBytes: 40, risk: .green)
        let moved = Counter()
        let tr = try trasher(t, moved: moved)
        let dry = await tr.trash([c, p])
        #expect(dry.refused.isEmpty && dry.totalBytes == 100 && dry.done.count == 1)
        #expect(dry.skipped.map(\.id) == [c.id] && dry.skipped[0].reason.contains("üst öğeyle birlikte"))
        let real = await tr.trash([c, p], dryRun: false)
        #expect(real.refused.isEmpty && real.totalBytes == 100 && moved.log == [parent.path])
        #expect(!t.exists(parent))
    }

    @Test("üst öğe reddedilirse alt öğe normal işlenir")
    func parentRefusedChildProceeds() async throws {
        let t = try TempTree()
        let parent = try t.dir("Library/Caches/P")
        let child = try t.file("Library/Caches/P/c/x.bin").deletingLastPathComponent()
        let p = CleanItem(category: .caches, name: "p", path: parent.path, allocatedBytes: 100, risk: .green, lockReason: "x")
        let c = CleanItem(category: .caches, name: "c", path: child.path, allocatedBytes: 40, risk: .green)
        let r = await (try trasher(t)).trash([p, c], dryRun: false)
        #expect(r.refused.count == 1 && r.done.map(\.id) == [c.id] && r.skipped.isEmpty)
    }

    @Test("motor tarama başında dataless indirmeyi süreç düzeyinde kapatır")
    func iopolicy() async throws {
        let t = try TempTree()
        _ = try await engine([]).scan(.test(t))
        #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS)
            == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }
}

// MARK: 3. Okunamayan klasör

@Suite("Okunamayan klasör")
struct UnreadableFolderTests {
    @Test("listelenemeyen klasör boş sayılmaz; büyük ve eski onu kapsayanı aday yapmaz")
    func unreadable() async throws {
        let t = try TempTree()
        let locked = try t.dir("projeler/kilitli")
        try t.file("projeler/kilitli/gizli.txt")
        let empty = try t.dir("projeler/bos")
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o755) }
        let items = try await FoldersScanner().scan(.test(t))
        #expect(items.contains { $0.path == empty.path })
        #expect(!items.contains { $0.path == locked.path })

        let walker = FileWalker(cloudGuard: CloudGuard(home: t.home))
        let info = try #require(FS.info(locked.path))
        #expect(try walker.listChildren(of: info, rootDev: info.dev) == nil)

        // Büyük ve eski: kardeşleri büyük olsa da okunamayan alt klasörü olan klasör aday olmaz.
        try t.file("projeler/a.bin", bytes: 64 * 1024)
        try t.file("projeler/b.bin", bytes: 64 * 1024)
        let lo = LargeOldScanner(minFileBytes: 32 * 1024, folderCandidateBytes: 100 * 1024)
        let found = try await lo.scan(.test(t))
        #expect(!found.contains { $0.path.hasSuffix("/projeler") })
        #expect(found.filter { $0.path.hasSuffix(".bin") }.count == 2)
    }
}

// MARK: 5. Aynı bundle id'li iki uygulama

@Suite("Aynı bundle id")
struct TwinAppsTests {
    @Test("aynı bundle id'li iki kopya: artıklar eklenmez; Trasher artıklı öğeyi reddeder")
    func twins() async throws {
        let t = try TempTree()
        let (apps, policy) = try AppFixture.setup(t)
        let a = try AppFixture.app(t, in: apps, "Foo", id: "com.example.foo")
        let b = try AppFixture.app(t, in: t.home.appending(path: "Applications"), "Foo Kopya", id: "com.example.foo")
        let cache = try t.dir("Library/Caches/com.example.foo")
        try t.file("x.bin", in: cache)
        var ctx = ScanContext.test(t, now: Date().addingTimeInterval(400 * 86_400))
        ctx.pathPolicy = policy
        let items = try await AppsScanner(binDirectories: []).scan(ctx)
        #expect(items.count == 2)
        for i in items {
            #expect(i.relatedPaths == nil)
            #expect(i.note?.contains("aynı bundle id'li başka kopya") == true)
        }
        let forged = AppFixture.appItem(a, related: [cache])
        let moved = Counter()
        let tr = Trasher(policy: policy, commands: FakeCommands(), processes: FakeProcesses(),
                         selfExecutable: nil, selfBundleID: nil, mover: try AppFixture.mover(t, counter: moved))
        let r = await tr.trash([forged], dryRun: false)
        #expect(r.done.isEmpty && r.refused.first?.reason.contains("aynı bundle id") == true)
        #expect(moved.n == 0 && t.exists(a) && t.exists(b) && t.exists(cache))
    }
}

// MARK: 6. Bulut ve git

@Suite("Bulut deposunda git")
struct CloudGitTests {
    func guardWith(dataless: Set<String>, ubiquitous: Set<String> = [], home: URL) -> CloudGuard {
        CloudGuard(home: home, probes: CloudGuard.Probes(
            isDataless: { dataless.contains($0.standardizedFileURL.path) },
            isDownloadedCurrent: { ubiquitous.contains($0.standardizedFileURL.path) ? true : nil },
            isRegularFile: { _ in true }
        ))
    }

    @Test("dataless ya da iCloud depo kökünde git hiç çalıştırılmaz")
    func skipGit() async throws {
        let t = try TempTree()
        let repo = try t.dir("projeler/bulut")
        try t.dir(".git", in: repo)
        try t.dir("node_modules/x", in: repo)
        try t.file("package.json", in: repo)
        let repo2 = try t.dir("projeler/icloud")
        try t.dir(".git", in: repo2)
        let g = guardWith(dataless: [repo.path], ubiquitous: [repo2.path], home: t.home)
        #expect(!g.isSafeForGit(repo) && !g.isSafeForGit(repo2))
        #expect(g.isSafeForGit(t.home.appending(path: "projeler")))

        let runner = ScriptedCommands(script: [("", ok("true"))])
        let live = LiveGitInfo(runner: runner, cloudGuard: g)
        #expect(await live.info(repo: repo) == nil && runner.counter.n == 0)

        var ctx = ScanContext.test(t, cloudGuard: g)
        ctx.signals.commands = runner
        ctx.signals.git = live
        ctx.roots = [t.home.appending(path: "projeler")]
        let items = try await ProjectArtifactsScanner().scan(ctx)
        #expect(items.contains { $0.path.hasSuffix("bulut/node_modules") })
        #expect(runner.counter.log.allSatisfy { !$0.hasPrefix("git") }, "\(runner.counter.log)")
    }

    @Test("bütün git çağrıları güvenli argümanlarla (fsmonitor ve kancalar kapalı)")
    func gitArgs() async throws {
        let t = try TempTree()
        let repo = try t.dir("projeler/p")
        try t.dir(".git", in: repo)
        try t.file("package.json", in: repo)
        try t.dir("dist/x", in: repo)
        try t.dir("node_modules/y", in: repo)
        let runner = ScriptedCommands(script: [("rev-parse", ok("true\n")), ("ls-files", ok("")), ("check-ignore", ok("")),
                                               ("log -1", ok("1600000000"))])
        var ctx = ScanContext.test(t)
        ctx.signals.commands = runner
        ctx.signals.git = LiveGitInfo(runner: runner, cloudGuard: ctx.cloudGuard)
        ctx.roots = [t.home.appending(path: "projeler")]
        _ = try await ProjectArtifactsScanner().scan(ctx)
        let gitCalls = runner.counter.log.filter { $0.hasPrefix("git ") }
        #expect(gitCalls.count >= 4)
        for c in gitCalls {
            #expect(c.contains("-c core.fsmonitor=false -c core.hooksPath=/dev/null --no-optional-locks -C "), "\(c)")
        }
        #expect(GitCommand.environment["GIT_CONFIG_NOSYSTEM"] == "1")
    }
}

// MARK: 7. Küçük sağlamlaştırmalar

@Suite("Sağlamlaştırma")
struct HardeningTests {
    @Test("tam özet döngüsü iptal edilebilir")
    func readerCancellation() async throws {
        let t = try TempTree()
        let f = try t.file("buyuk.bin", bytes: 3 << 20)
        let reader = SafeReader(cloudGuard: CloudGuard(home: t.home))
        let task = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            do {
                _ = try reader.sha256(f)
                return false
            } catch {
                if case SafeReader.ReadError.cancelled? = error as? SafeReader.ReadError { return true }
                return false
            }
        }
        task.cancel()
        #expect(await task.value)
    }

    @Test("zaman aşımı: süreç sonlanır; erken biten süreçte zaman aşımı işaretlenmez")
    func timeout() async throws {
        let quick = await ProcessCommandRunner.execute(executable: "/bin/sh", arguments: ["-c", "exit 0"],
                                                       environment: nil, timeout: .milliseconds(200))
        #expect(quick?.succeeded == true && quick?.timedOut == false)
        let slow = await ProcessCommandRunner.execute(executable: "/bin/sleep", arguments: ["5"],
                                                      environment: nil, timeout: .milliseconds(200))
        #expect(slow?.timedOut == true && slow?.succeeded == false)
    }
}

// MARK: 8. Varsayılan seçim

@Suite("Varsayılan seçim (preselect)")
struct PreselectTests {
    @Test("preselect false yeşili seçimden çıkarır; eski JSON geriye uyumlu")
    func model() throws {
        let base = CleanItem(category: .caches, name: "x", path: "/tmp/x", allocatedBytes: 1, risk: .green)
        #expect(base.isDefaultSelected)
        var off = base
        off.preselect = false
        #expect(!off.isDefaultSelected)
        // Yeni alanlar olmadan kodlanmış eski öğe çözülür.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as! [String: Any]
        for k in ["preselect", "groupID", "keeperPath"] { json.removeValue(forKey: k) }
        let decoded = try JSONDecoder().decode(CleanItem.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == base && decoded.preselect == nil && decoded.groupID == nil)
    }

    @Test("30 günden yeni proje artığı yeşil ama seçili değil; eski olan seçili")
    func projectArtifacts() async throws {
        let t = try TempTree()
        let fresh = try t.dir("projeler/yeni")
        try t.file("package.json", in: fresh)
        try t.dir("node_modules/a", in: fresh)
        let old = try t.dir("projeler/eski")
        try t.file("package.json", in: old)
        try t.dir("node_modules/a", in: old)
        age(fresh, days: 3)
        age(old, days: 60)
        let items = try await ProjectArtifactsScanner().scan(context(t, roots: [t.home.appending(path: "projeler")]))
        let f = try #require(items.first { $0.path.hasSuffix("yeni/node_modules") })
        let o = try #require(items.first { $0.path.hasSuffix("eski/node_modules") })
        #expect(f.risk == .green && f.preselect == false && !f.isDefaultSelected)
        #expect(o.risk == .green && o.isDefaultSelected)
    }

    @Test("son 1 günde kullanılan Xcode proje derlemesi seçili değil")
    func derivedData() async throws {
        let t = try TempTree()
        let hash = String(repeating: "b", count: 28)
        let dd = "Library/Developer/Xcode/DerivedData"
        try t.file("\(dd)/Yeni-\(hash)/Build/a.o")
        try t.file("\(dd)/Eski-\(hash)/Build/a.o")
        age(t.home.appending(path: "\(dd)/Yeni-\(hash)"), days: 0, now: Date().addingTimeInterval(-3 * 3600))
        age(t.home.appending(path: "\(dd)/Eski-\(hash)"), days: 5)
        let items = try await XcodeScanner().scan(context(t))
        let y = try #require(items.first { $0.name == "DerivedData: Yeni" })
        let e = try #require(items.first { $0.name == "DerivedData: Eski" })
        #expect(!y.isLocked && !y.isDefaultSelected)
        #expect(e.isDefaultSelected)
    }
}

// MARK: 9. Mükerrer grupları ve Trasher

@Suite("Mükerrer grupları")
struct DuplicateGroupTrashTests {
    func dup(_ url: URL, keeper: URL, group: String = "g1", risk: Risk = .green, method: CleanMethod = .trash) -> CleanItem {
        CleanItem(category: .duplicates, name: url.lastPathComponent, path: url.path, allocatedBytes: 10, risk: risk,
                  method: method, groupID: group, keeperPath: keeper.path)
    }

    @Test("tutulacak kopya asla taşınmaz (yeşil/trash diye değiştirilse bile)")
    func keeperNeverMoves() async throws {
        let t = try TempTree()
        let keeper = try t.file("Documents/a.pdf")
        let copy = try t.file("Downloads/a1.pdf")
        // Taramadaki gerçek öğeler: tutulacak kopya bilgi/yöntemsiz.
        let scan = [dup(keeper, keeper: keeper, risk: .info, method: .none), dup(copy, keeper: keeper)]
        let moved = Counter()
        let tr = try trasher(t, moved: moved)

        // Arayüzden değiştirilmiş öğe: grup alanları silinmiş, yeşil, Çöp Kutusu yöntemi.
        var forged = CleanItem(category: .duplicates, name: "a.pdf", path: keeper.path, allocatedBytes: 10, risk: .green,
                               method: .trash)
        #expect(forged.id == scan[0].id && forged.groupID == nil)
        var r = await tr.trash([forged], dryRun: false, scanItems: scan)
        #expect(r.done.isEmpty && r.refused.first?.reason == "öğe tarama sonucundan farklı")
        // Grup alanları duruyor ama risk/yöntem değiştirilmiş.
        forged = dup(keeper, keeper: keeper)
        r = await tr.trash([forged], dryRun: false, scanItems: scan)
        #expect(r.done.isEmpty && r.refused.count == 1)
        // id ile: tarama öğesi bilgi öğesi.
        r = await tr.trash(ids: [scan[0].id], scan: scan, dryRun: false)
        #expect(r.done.isEmpty && r.refused.first?.reason == "yalnız bilgi")
        // Tarama da değiştirilmiş olsa bile (yeşil/trash) tutulacak kopya kuralı reddeder.
        r = await tr.trash([forged], dryRun: false, scanItems: [forged])
        #expect(r.done.isEmpty && r.refused.first?.reason == "grubun tutulacak kopyası")
        #expect(moved.n == 0 && t.exists(keeper))
    }

    @Test("aynı çalıştırmada üst klasörü taşınan kopya kalan sayılmaz")
    func copyInsideMovedFolder() async throws {
        let t = try TempTree()
        let keeper = try t.file("Documents/a.pdf")
        let c1 = try t.file("Downloads/a1.pdf")
        let c2 = try t.file("Downloads/klasor/a2.pdf")
        let folder = CleanItem(category: .largeOld, name: "klasor", path: c2.deletingLastPathComponent().path,
                               allocatedBytes: 10, risk: .green)
        let scan = [dup(keeper, keeper: keeper, risk: .info, method: .none), dup(c1, keeper: keeper), dup(c2, keeper: keeper),
                    folder]
        // Tutulacak kopya taramadan sonra silinmiş: c2 klasörle gidecek, c1 kalmalı.
        try FileManager.default.removeItem(at: keeper)
        let moved = Counter()
        let r = await (try trasher(t, moved: moved)).trash(ids: [scan[1].id, folder.id], scan: scan, dryRun: false)
        #expect(r.refused.count == 1 && r.refused.first?.id == scan[1].id)
        #expect(r.refused.first?.reason.contains("son kopyası") == true)
        #expect(r.done.map(\.id) == [folder.id])
        #expect(t.exists(c1) && !t.exists(c2))
    }

    @Test("grup alanları başka kategoride reddedilir")
    func wrongCategory() async throws {
        let t = try TempTree()
        let f = try t.file("Library/Caches/a.bin")
        var item = CleanItem(category: .caches, name: "a", path: f.path, allocatedBytes: 1, risk: .green, groupID: "g")
        item.keeperPath = "/tmp/x"
        #expect(try trasher(t).rejectionReason(for: item) != nil)
    }

    @Test("bir grubun hiç kopyası kalmayacaksa son kopya reddedilir")
    func lastCopy() async throws {
        let t = try TempTree()
        let keeper = try t.file("Documents/a.pdf")
        let c1 = try t.file("Downloads/a1.pdf")
        let c2 = try t.file("Downloads/a2.pdf")
        let items = [dup(c1, keeper: keeper), dup(c2, keeper: keeper)]
        let keeperItem = dup(keeper, keeper: keeper, risk: .info, method: .none)

        // Tutulacak kopya duruyor: iki kopya da taşınır.
        let ok = await (try trasher(t)).trash(items, scanItems: items + [keeperItem])
        #expect(ok.refused.isEmpty && ok.done.count == 2)

        // Tutulacak kopya taramadan sonra silinmiş: biri kalmalı.
        try FileManager.default.removeItem(at: keeper)
        let moved = Counter()
        let r = await (try trasher(t, moved: moved)).trash(items, dryRun: false, scanItems: items + [keeperItem])
        #expect(r.done.count == 1 && r.refused.count == 1)
        #expect(r.refused[0].reason.contains("son kopyası"))
        #expect(t.exists(c1) != t.exists(c2))

        // Tarama öğeleri verilmeden de: tutulacak yol yoksa son kopya bırakılır.
        let t2 = try TempTree()
        let k2 = t2.home.appending(path: "Documents/yok.pdf")
        let d1 = try t2.file("Downloads/b.pdf")
        let r2 = await (try trasher(t2)).trash([dup(d1, keeper: k2)])
        #expect(r2.done.isEmpty && r2.refused.count == 1)
    }
}

// MARK: 12. Tarayıcı başına varsayılan kökler

@Suite("Varsayılan kökler")
struct DefaultRootsTests {
    @Test("kök verilmezse tarayıcı kendi varsayılanını, verilirse hepsi verileni kullanır")
    func roots() async throws {
        let t = try TempTree()
        let none = ScanContext(home: t.home, roots: nil, signals: .fake())
        #expect(none.explicitRoots == nil)
        #expect(none.roots == ScanContext.defaultRoots(home: t.home))
        #expect(none.roots(default: [t.home]) == [t.home])
        let given = ScanContext(home: t.home, roots: [t.home.appending(path: "x")], signals: .fake())
        #expect(given.roots(default: [t.home]) == [t.home.appending(path: "x")])

        // Mükerrer: kök verilmezse ana klasörün tamamı (projeler/Desktop dışındaki kopyalar da bulunur).
        try t.file("Downloads/a.bin", bytes: 3000)
        try t.file("Music/a.bin", bytes: 3000)
        let dups = DuplicatesScanner(minBytes: 1024, prefixBytes: 64)
        #expect(try await dups.scan(none).count == 2)
        let narrowed = ScanContext(home: t.home, roots: [t.home.appending(path: "Downloads")], signals: .fake())
        #expect(try await dups.scan(narrowed).isEmpty)
    }
}

// MARK: 13. Trasher yalnız tarama sonucuna güvenir

@Suite("Trasher: güvenilir kaynak tarama sonucu")
struct TrasherScanTrustTests {
    @Test("değiştirilmiş kilitli öğe reddedilir (risk ve kilit nedeni silinse bile)")
    func forgedLocked() async throws {
        let t = try TempTree()
        let f = try t.file("Library/Caches/app/a.bin")
        let locked = CleanItem(category: .caches, name: "app", path: f.deletingLastPathComponent().path, allocatedBytes: 10,
                               risk: .locked, lockReason: "çalışıyor")
        var forged = locked
        forged.risk = .green
        forged.lockReason = nil
        let moved = Counter()
        let tr = try trasher(t, moved: moved)
        let r = await tr.trash([forged], dryRun: false, scanItems: [locked])
        #expect(r.done.isEmpty && r.refused.first?.reason == "öğe tarama sonucundan farklı")
        let r2 = await tr.trash(ids: [locked.id], scan: [locked], dryRun: false)
        #expect(r2.done.isEmpty && r2.refused.first?.reason.hasPrefix("kilitli") == true)
        #expect(moved.n == 0 && t.exists(f))
    }

    @Test("id aynı, yol farklı öğe reddedilir")
    func forgedPath() async throws {
        let t = try TempTree()
        let safe = try t.file("Library/Caches/x/a.bin")
        let victim = try t.file("Documents/tez.docx")
        let scanned = CleanItem(category: .caches, name: "x", path: safe.deletingLastPathComponent().path, allocatedBytes: 1,
                                risk: .green)
        var forged = scanned
        forged.path = victim.path
        let moved = Counter()
        let r = await (try trasher(t, moved: moved)).trash([forged], dryRun: false, scanItems: [scanned])
        #expect(r.done.isEmpty && r.refused.count == 1 && r.refused[0].reason == "öğe tarama sonucundan farklı")
        #expect(moved.n == 0 && t.exists(victim))
    }

    @Test("taramada olmayan ya da taramada birden çok geçen id reddedilir")
    func unknownID() async throws {
        let t = try TempTree()
        let f = try t.file("Library/Caches/y/a.bin")
        let item = CleanItem(category: .caches, name: "y", path: f.deletingLastPathComponent().path, allocatedBytes: 1,
                             risk: .green)
        let moved = Counter()
        let tr = try trasher(t, moved: moved)
        let r = await tr.trash([item], dryRun: false, scanItems: [])
        #expect(r.done.isEmpty && r.refused.first?.reason == "bu taramada bulunamadı")
        let r2 = await tr.trash(ids: ["yok", item.id], scan: [], dryRun: false)
        #expect(r2.done.isEmpty && r2.refused.count == 2)
        let r3 = await tr.trash(ids: [item.id], scan: [item, item], dryRun: false)
        #expect(r3.done.isEmpty && r3.refused.first?.reason == "taramada birden çok aynı id")
        #expect(moved.n == 0 && t.exists(f))
        // Eşleşen öğe kabul edilir.
        let ok = await tr.trash([item], dryRun: false, scanItems: [item])
        #expect(ok.refused.isEmpty && ok.done.count == 1 && moved.n == 1)
    }
}
