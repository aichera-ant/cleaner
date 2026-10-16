import Darwin
import Foundation
import Testing
@testable import CleanerKit

/// Komut → sonuç eşlemesi olan sahte çalıştırıcı. Eşleşme yoksa `nil` (araç yok) döner.
struct ScriptedCommands: CommandRunning {
    /// (komut satırında geçen metin, sonuç). İlk eşleşen kazanır.
    var script: [(String, CommandResult)]
    var counter = Counter()

    func run(_ tool: String, _ arguments: [String], timeout: Duration) async -> CommandResult? {
        let line = ([tool] + arguments).joined(separator: " ")
        counter.hit(line)
        return script.first { line.contains($0.0) }?.1
    }

    func runShell(_ command: String, timeout: Duration) async -> CommandResult? {
        counter.hit(command)
        return nil
    }
}

func ok(_ s: String) -> CommandResult { CommandResult(exitCode: 0, stdout: s) }

/// Ağaçtaki her şeyin değişiklik tarihini `days` gün öncesine çeker (derinden yüzeye).
func age(_ url: URL, days: Int, now: Date = Date()) {
    let date = now.addingTimeInterval(-Double(days) * 86_400)
    var all: [String] = [url.path]
    if let e = FileManager.default.enumerator(atPath: url.path) {
        while let rel = e.nextObject() as? String { all.append(url.appending(path: rel).path) }
    }
    for p in all.reversed() { try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: p) }
}

func context(_ t: TempTree, roots: [URL]? = nil, commands: [(String, CommandResult)] = [],
             processes: [String] = [], git: FakeGit = FakeGit()) -> ScanContext {
    var c = ScanContext.test(t, signals: .fake(commands: FakeCommands(), processes: FakeProcesses(names: processes), git: git))
    c.signals.commands = ScriptedCommands(script: commands)
    if let roots { c.roots = roots }
    return c
}

// MARK: Xcode

@Suite("XcodeScanner")
struct XcodeScannerTests {
    let hash = String(repeating: "a", count: 28)

    @Test("DerivedData: proje, worktree derlemesi ve önbellekler ayrı bulunur; yeni değişen kilitli")
    func derivedData() async throws {
        let t = try TempTree()
        let dd = "Library/Developer/Xcode/DerivedData"
        try t.file("\(dd)/Hepp-\(hash)/Build/a.o", bytes: 50_000)
        try t.file("\(dd)/hepp-1d9-x/Build/a.o", bytes: 50_000)
        try t.file("\(dd)/ModuleCache.noindex/m", bytes: 50_000)
        let base = t.home.appending(path: dd)
        age(base.appending(path: "Hepp-\(hash)"), days: 20)
        age(base.appending(path: "hepp-1d9-x"), days: 5)
        age(base.appending(path: "ModuleCache.noindex"), days: 5)
        try t.file("\(dd)/hepp-1d9-y/Build/a.o", bytes: 1000) // şimdi oluşturuldu: kilitli

        let items = try await XcodeScanner().scan(context(t))
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(byName["DerivedData: Hepp"]?.risk == .green)
        #expect(byName["DerivedData: Hepp"]?.isDefaultSelected == true)
        #expect(byName["Worktree derlemesi: hepp-1d9-x"]?.risk == .green)
        #expect(byName["Xcode önbelleği: ModuleCache.noindex"] != nil)
        #expect(byName["Worktree derlemesi: hepp-1d9-y"]?.isLocked == true)
        #expect(byName["DerivedData: Hepp"]?.allocatedBytes ?? 0 >= 50_000)
        #expect(byName["DerivedData: Hepp"]?.dateSignal == .modified(days: 20))
    }

    @Test("Archives ve DeviceSupport yalnız 90 günden eski olanlar, sarı")
    func archivesAndSupport() async throws {
        let t = try TempTree()
        let x = "Library/Developer/Xcode"
        try t.file("\(x)/Archives/2026-01-01/Eski.xcarchive/p", bytes: 5000)
        try t.file("\(x)/Archives/2026-10-01/Yeni.xcarchive/p", bytes: 5000)
        try t.file("\(x)/iOS DeviceSupport/iPhone15,2 17.0/s", bytes: 5000)
        age(t.home.appending(path: "\(x)/Archives/2026-01-01/Eski.xcarchive"), days: 200)
        age(t.home.appending(path: "\(x)/Archives/2026-10-01/Yeni.xcarchive"), days: 3)
        age(t.home.appending(path: "\(x)/iOS DeviceSupport/iPhone15,2 17.0"), days: 120)

        let items = try await XcodeScanner().scan(context(t))
        #expect(items.count == 2)
        #expect(items.contains { $0.name == "Arşiv: Eski" && $0.risk == .yellow && !$0.isDefaultSelected })
        #expect(items.contains { $0.name.hasPrefix("iOS DeviceSupport") && $0.risk == .yellow })
    }

    @Test("Simülatörler: Booted kilitli, unavailable yeşil, diğerleri sarı ve seçili değil; komut yöntemi")
    func simulators() async throws {
        let t = try TempTree()
        let ids = ["AAAAAAAA-0000-0000-0000-000000000001", "AAAAAAAA-0000-0000-0000-000000000002",
                   "AAAAAAAA-0000-0000-0000-000000000003"]
        for id in ids { try t.file("Library/Developer/CoreSimulator/Devices/\(id)/data/x", bytes: 8000) }
        for id in ids { age(t.home.appending(path: "Library/Developer/CoreSimulator/Devices/\(id)"), days: 40) }
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
          {"udid":"\(ids[0])","name":"iPhone Açık","state":"Booted","isAvailable":true},
          {"udid":"\(ids[1])","name":"iPhone Kapalı","state":"Shutdown","isAvailable":true},
          {"udid":"\(ids[2])","name":"iPhone Eski","state":"Shutdown","isAvailable":false},
          {"udid":"BBBBBBBB-0000-0000-0000-000000000009","name":"Disk yok","state":"Shutdown","isAvailable":true}]}}
        """
        let items = try await XcodeScanner().scan(context(t, commands: [("simctl list", ok(json))]))
        let by = Dictionary(uniqueKeysWithValues: items.map { ($0.name.components(separatedBy: " (").first!, $0) })
        #expect(items.count == 3)
        #expect(by["Simülatör: iPhone Açık"]?.isLocked == true)
        #expect(by["Simülatör: iPhone Kapalı"]?.risk == .yellow)
        #expect(by["Simülatör: iPhone Kapalı"]?.isDefaultSelected == false)
        #expect(by["Simülatör: iPhone Eski"]?.risk == .green)
        #expect(by["Simülatör: iPhone Eski"]?.method == .command("xcrun simctl delete \(ids[2])"))
    }

    @Test("Araç ve klasör yokken boş döner")
    func empty() async throws {
        let t = try TempTree()
        #expect(try await XcodeScanner().scan(context(t)).isEmpty)
    }

    @Test("DerivedData ad ayrımı")
    func names() {
        #expect(XcodeScanner.isStandardDerivedDataName("Hepp-glgsttbqwrmojuexwwqjjzdlyspt"))
        #expect(!XcodeScanner.isStandardDerivedDataName("hepp-1d9-x"))
        #expect(!XcodeScanner.isStandardDerivedDataName("ModuleCache.noindex"))
    }
}

// MARK: Proje artıkları

@Suite("ProjectArtifactsScanner")
struct ProjectArtifactsScannerTests {
    @Test("node_modules, .next, .next-*, .turbo bulunur; iç içe node_modules ayrı sayılmaz")
    func finds() async throws {
        let t = try TempTree()
        let p = try t.dir("projeler/app")
        try t.file("package.json", in: p)
        try t.file("node_modules/a/index.js", bytes: 20_000, in: p)
        try t.file("node_modules/a/node_modules/b/index.js", bytes: 20_000, in: p)
        try t.file(".next/cache/x", bytes: 20_000, in: p)
        try t.file(".next-e2e/x", bytes: 20_000, in: p)
        try t.file(".turbo/x", bytes: 20_000, in: p)
        age(p, days: 60)

        let ctx = context(t, roots: [t.home.appending(path: "projeler")])
        let items = try await ProjectArtifactsScanner().scan(ctx)
        #expect(Set(items.map(\.name)) == ["node_modules (app)", ".next (app)", ".next-e2e (app)", ".turbo (app)"])
        #expect(items.allSatisfy { $0.risk == .green && $0.isDefaultSelected && $0.dateSignal == .modified(days: 60) })
        let nm = try #require(items.first { $0.name.hasPrefix("node_modules") })
        #expect(nm.allocatedBytes >= 40_000) // iç içe olan üst öğeye dahil
    }

    @Test("Yeni etkinlik: not düşer; son 1 saatte değişen kilitli")
    func recentAndLocked() async throws {
        let t = try TempTree()
        let p = try t.dir("projeler/yeni")
        try t.file("package.json", in: p)
        try t.file("node_modules/a", bytes: 5000, in: p)
        try t.file(".turbo/a", bytes: 5000, in: p)
        age(p.appending(path: "package.json"), days: 3)
        age(p.appending(path: "node_modules"), days: 3)
        // .turbo şimdi değişti → kilitli

        let items = try await ProjectArtifactsScanner().scan(context(t, roots: [t.home.appending(path: "projeler")]))
        let nm = try #require(items.first { $0.name.hasPrefix("node_modules") })
        #expect(nm.note?.contains("30 günden yeni") == true)
        #expect(nm.isLocked == false)
        let turbo = try #require(items.first { $0.name.hasPrefix(".turbo") })
        #expect(turbo.isLocked)
    }

    @Test("dist/build yalnız package.json varsa ve git'te takipli değilse; takipli olan çıkmaz")
    func distBuild() async throws {
        let t = try TempTree()
        let a = try t.dir("projeler/a")
        try t.file("package.json", in: a)
        try t.file(".git/HEAD", in: a)
        try t.file("dist/x.js", in: a)
        try t.file("build/y.js", in: a)
        let b = try t.dir("projeler/b") // package.json yok → dist alınmaz
        try t.file(".git/HEAD", in: b)
        try t.file("dist/x.js", in: b)
        for d in [a, b] { age(d, days: 60) }

        let gitInfo = GitInfo(remoteURL: nil, firstCommit: "x", isDirty: false, hasUnpushedCommits: false)
        let git = FakeGit(infos: [a.path: gitInfo, b.path: gitInfo])
        let cmds: [(String, CommandResult)] = [
            ("ls-files -- dist", ok("dist/x.js\n")), // dist takipli
            ("ls-files -- build", ok("")),
            ("check-ignore -q -- build", CommandResult(exitCode: 0, stdout: "")), // build yok sayılıyor
            ("log -1", ok("1700000000\n")),
        ]
        let items = try await ProjectArtifactsScanner().scan(
            context(t, roots: [t.home.appending(path: "projeler")], commands: cmds, git: git))
        #expect(items.map(\.name) == ["build (a)"])
        #expect(items[0].risk == .green)
    }

    @Test("git ignore'da olmayan, takipsiz dist sarı olur")
    func untrackedDist() async throws {
        let t = try TempTree()
        let a = try t.dir("projeler/a")
        try t.file("package.json", in: a)
        try t.file(".git/HEAD", in: a)
        try t.file("dist/x.js", in: a)
        age(a, days: 60)
        let git = FakeGit(infos: [a.path: GitInfo(remoteURL: nil, firstCommit: "x", isDirty: false, hasUnpushedCommits: false)])
        let cmds: [(String, CommandResult)] = [
            ("ls-files", ok("")), ("check-ignore", CommandResult(exitCode: 1, stdout: "")), ("log -1", ok("1700000000")),
        ]
        let items = try await ProjectArtifactsScanner().scan(
            context(t, roots: [t.home.appending(path: "projeler")], commands: cmds, git: git))
        #expect(items.first?.risk == .yellow)
    }

    @Test("Kirli depoda node_modules yeşil kalır, nota yazılır")
    func dirtyRepo() async throws {
        let t = try TempTree()
        let a = try t.dir("projeler/a")
        try t.file("package.json", in: a)
        try t.file(".git/HEAD", in: a)
        try t.file("node_modules/x", in: a)
        age(a, days: 60)
        let git = FakeGit(infos: [a.path: GitInfo(remoteURL: nil, firstCommit: "x", isDirty: true, hasUnpushedCommits: true)])
        let items = try await ProjectArtifactsScanner().scan(
            context(t, roots: [t.home.appending(path: "projeler")], commands: [("log -1", ok("1600000000"))], git: git))
        let nm = try #require(items.first)
        #expect(nm.risk == .green)
        #expect(nm.note?.contains("commit edilmemiş değişiklik ve push edilmemiş commit") == true)
    }

    @Test("Derinlik sınırı: çok derindeki proje taranmaz")
    func depth() async throws {
        let t = try TempTree()
        let deep = try t.dir("projeler/a/b/c/d/e/f")
        try t.file("package.json", in: deep)
        try t.file("node_modules/x", in: deep)
        let shallow = try t.dir("projeler/a/b")
        try t.file("package.json", in: shallow)
        try t.file("node_modules/x", in: shallow)
        let items = try await ProjectArtifactsScanner().scan(context(t, roots: [t.home.appending(path: "projeler")]))
        #expect(items.count == 1)
        #expect(items[0].path.hasSuffix("projeler/a/b/node_modules"))
    }

    @Test("Proje değilse (işaretçi yok) artık alınmaz; kök yoksa boş")
    func notProject() async throws {
        let t = try TempTree()
        let p = try t.dir("projeler/x")
        try t.file("node_modules/a", in: p)
        #expect(try await ProjectArtifactsScanner().scan(context(t, roots: [t.home.appending(path: "projeler")])).isEmpty)
        #expect(try await ProjectArtifactsScanner().scan(context(t, roots: [t.home.appending(path: "yok")])).isEmpty)
    }
}

// MARK: Docker

@Suite("DockerScanner")
struct DockerScannerTests {
    let ps = """
    {"ID":"aaaa1111bbbb","Names":"calisan","State":"running","Status":"Up 2 hours","Size":"86kB (virtual 1.39GB)"}
    {"ID":"cccc2222dddd","Names":"kapali","State":"exited","Status":"Exited (0) 2 days ago","Size":"2.5MB (virtual 100MB)"}
    """
    let df = """
    {"Images":[
      {"ID":"sha256:1111111111111111","Repository":"kullanilan","Tag":"1","Containers":"1","Size":"587MB","UniqueSize":"587.2MB"},
      {"ID":"sha256:2222222222222222","Repository":"bos","Tag":"2","Containers":"0","Size":"1.5GB","UniqueSize":"N/A"}],
     "Containers":[],
     "Volumes":[{"Name":"sahipsiz_vol","Size":"430MB","Links":"0"},{"Name":"kullanilan_vol","Size":"1GB","Links":"1"}],
     "BuildCache":[{"ID":"x","Size":"100MB","InUse":false},{"ID":"y","Size":"50MB","InUse":false}]}
    """
    var script: [(String, CommandResult)] {
        [("ps -a", ok(ps)), ("system df", ok(df)),
         ("volume ls", ok("{\"Name\":\"sahipsiz_vol\"}\n"))]
    }

    @Test("container, imaj, volume ve build cache doğru risk ve komutla bulunur")
    func finds() async throws {
        let t = try TempTree()
        let items = try await DockerScanner().scan(context(t, commands: script))
        let by = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(by["Container: calisan"]?.isLocked == true)
        #expect(by["Container: kapali"]?.risk == .yellow)
        #expect(by["Container: kapali"]?.isDefaultSelected == false)
        #expect(by["Container: kapali"]?.method == .command("docker rm -- cccc2222dddd"))
        #expect(by["İmaj: bos:2"]?.risk == .yellow)
        #expect(by["İmaj: bos:2"]?.method == .command("docker rmi -- 2222222222222222"))
        #expect(by["İmaj: bos:2"]?.allocatedBytes == 1_500_000_000)
        #expect(by["İmaj: kullanilan:1"] == nil)
        #expect(by["Volume: sahipsiz_vol"]?.risk == .red)
        #expect(by["Volume: sahipsiz_vol"]?.method == .command("docker volume rm -- sahipsiz_vol"))
        #expect(by["Volume: sahipsiz_vol"]?.allocatedBytes == 430_000_000)
        #expect(by["Volume: sahipsiz_vol"]?.isDefaultSelected == false)
        #expect(by["Docker build cache"]?.allocatedBytes == 150_000_000)
        #expect(by["Docker build cache"]?.method == .command("docker builder prune -f"))
        #expect(items.allSatisfy { $0.id == CleanItem.makeID(path: $0.path) })
    }

    @Test("Docker yoksa ya da daemon kapalıysa boş döner")
    func noDocker() async throws {
        let t = try TempTree()
        #expect(try await DockerScanner().scan(context(t)).isEmpty)
        let down = [("ps -a", CommandResult(exitCode: 1, stdout: "", stderr: "Cannot connect"))]
        #expect(try await DockerScanner().scan(context(t, commands: down)).isEmpty)
        let slow = [("ps -a", CommandResult(exitCode: 0, stdout: ps, timedOut: true))]
        #expect(try await DockerScanner().scan(context(t, commands: slow)).isEmpty)
    }

    @Test("Komut enjeksiyonu: güvensiz kimlik atlanır")
    func unsafeID() async throws {
        let t = try TempTree()
        let bad = [("ps -a", ok("{\"ID\":\"a;rm -rf ~\",\"Names\":\"x\",\"State\":\"exited\"}"))]
        #expect(try await DockerScanner().scan(context(t, commands: bad)).isEmpty)
    }

    @Test("colima disk dosyası bilgi öğesi: ayrılan boyut küçük, taşınamaz")
    func colima() async throws {
        let t = try TempTree()
        let f = t.home.appending(path: ".colima/_lima/_disks/colima/datadisk")
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(f.path, O_CREAT | O_WRONLY, 0o644)
        _ = ftruncate(fd, 5 * 1024 * 1024 * 1024)
        close(fd)
        let items = try await DockerScanner().scan(context(t))
        let item = try #require(items.first)
        #expect(item.risk == .info)
        #expect(item.method == .none)
        #expect(!item.isDefaultSelected)
        #expect(item.allocatedBytes < 1_000_000)
        #expect(item.note?.contains("görünen") == true)
    }

    @Test("boyut ayrıştırma")
    func sizes() {
        #expect(DockerScanner.parseSize("587MB") == 587_000_000)
        #expect(DockerScanner.parseSize("1.39GB") == 1_390_000_000)
        #expect(DockerScanner.parseSize("86kB") == 86_000)
        #expect(DockerScanner.parseSize("0B") == 0)
        #expect(DockerScanner.parseSize("N/A") == 0)
    }
}

// MARK: Eski sürümler

@Suite("OldVersionsScanner")
struct OldVersionsScannerTests {
    @Test("sürüm karşılaştırması anlamsal")
    func compare() {
        #expect(OldVersionsScanner.compare("2.1.300", "2.1.99") > 0)
        #expect(OldVersionsScanner.compare("v22.9.0", "v22.10.0") < 0)
        #expect(OldVersionsScanner.compare("1.2", "1.2.0") == 0)
    }

    @Test("Claude Code: en yüksek sürüm kilitli, çalışan eski sürüm kilitli, diğerleri yeşil")
    func claude() async throws {
        let t = try TempTree()
        for v in ["2.1.99", "2.1.296", "2.1.300"] { try t.file(".local/share/claude/versions/\(v)", bytes: 9000) }
        for v in ["2.1.99", "2.1.296", "2.1.300"] { age(t.home.appending(path: ".local/share/claude/versions/\(v)"), days: 10) }
        var ctx = context(t)
        ctx.signals.processes = RunningVersionProcess(path: t.home.path + "/.local/share/claude/versions/2.1.296")
        let items = try await OldVersionsScanner().scan(ctx)
        let by = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(by["Claude Code 2.1.300"]?.isLocked == true)
        #expect(by["Claude Code 2.1.296"]?.lockReason?.contains("çalışıyor") == true)
        #expect(by["Claude Code 2.1.99"]?.risk == .green)
        #expect(by["Claude Code 2.1.99"]?.isDefaultSelected == true)
    }

    @Test("Eklentiler: aynı yayıncı.ad'ın en yeni sürümü kilitli; tek sürümlü öğe olmaz")
    func extensions() async throws {
        let t = try TempTree()
        let e = ".vscode/extensions"
        for n in ["anthropic.claude-code-2.1.292-darwin-arm64", "anthropic.claude-code-2.1.296-darwin-arm64",
                  "ms-python.python-2026.4.0-universal"] {
            try t.file("\(e)/\(n)/f", bytes: 3000)
            age(t.home.appending(path: "\(e)/\(n)"), days: 20)
        }
        try t.file("\(e)/extensions.json", bytes: 10)
        let a = ".antigravity-ide/extensions"
        for n in ["golang.go-0.54.0-universal", "golang.go-0.56.1-universal"] {
            try t.file("\(a)/\(n)/f", bytes: 3000)
            age(t.home.appending(path: "\(a)/\(n)"), days: 20)
        }
        let items = try await OldVersionsScanner().scan(context(t))
        #expect(items.count == 4)
        #expect(items.first { $0.name.contains("2.1.292") }?.risk == .green)
        #expect(items.first { $0.name.contains("2.1.296") }?.isLocked == true)
        #expect(items.first { $0.name.contains("go-0.54.0") }?.isDefaultSelected == true)
        #expect(items.first { $0.name.contains("go-0.56.1") }?.isLocked == true)
    }

    @Test("fnm: varsayılan sürüm kilitli, diğeri sarı; nvm: alias okunur")
    func node() async throws {
        let t = try TempTree()
        for v in ["v22.1.0", "v24.0.0"] {
            try t.file(".local/share/fnm/node-versions/\(v)/installation/bin/node", bytes: 4000)
            age(t.home.appending(path: ".local/share/fnm/node-versions/\(v)"), days: 30)
        }
        try FileManager.default.createDirectory(at: t.home.appending(path: ".local/share/fnm/aliases"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: t.home.appending(path: ".local/share/fnm/aliases/default").path,
            withDestinationPath: t.home.appending(path: ".local/share/fnm/node-versions/v24.0.0/installation").path)
        for v in ["v18.0.0", "v20.1.0"] {
            try t.file(".nvm/versions/node/\(v)/bin/node", bytes: 4000)
            age(t.home.appending(path: ".nvm/versions/node/\(v)"), days: 30)
        }
        try t.file(".nvm/alias/default", bytes: 0)
        try Data("20\n".utf8).write(to: t.home.appending(path: ".nvm/alias/default"))

        let items = try await OldVersionsScanner().scan(context(t))
        let by = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(by["Node v24.0.0 (fnm)"]?.isLocked == true)
        #expect(by["Node v22.1.0 (fnm)"]?.risk == .yellow)
        #expect(by["Node v22.1.0 (fnm)"]?.isDefaultSelected == false)
        #expect(by["Node v20.1.0 (nvm)"]?.isLocked == true)
        #expect(by["Node v18.0.0 (nvm)"]?.risk == .yellow)
    }

    @Test("hiçbir şey kurulu değilse boş")
    func empty() async throws {
        let t = try TempTree()
        #expect(try await OldVersionsScanner().scan(context(t)).isEmpty)
    }
}

struct RunningVersionProcess: ProcessListing {
    var path: String
    func runningProcesses() -> [RunningProcess] { [RunningProcess(pid: 4242, name: "claude", path: path)] }
}
