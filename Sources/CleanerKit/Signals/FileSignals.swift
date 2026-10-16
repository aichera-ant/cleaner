import CoreServices
import Darwin
import Foundation

/// Spotlight "son açılış" bilgisi. Kayıt yoksa nil (TESPITLER ders 2: çoğu zaman yoktur).
public protocol SpotlightProviding: Sendable {
    func lastUsedDate(_ url: URL) -> Date?
}

/// `MDItem` + `kMDItemLastUsedDate`. Yalnız Spotlight dizinini sorgular; dosya içeriği okunmaz.
public struct LiveSpotlight: SpotlightProviding {
    public init() {}

    public func lastUsedDate(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        guard let value = MDItemCopyAttribute(item, kMDItemLastUsedDate) else { return nil }
        return (value as? Date)
    }
}

/// Dosya tarihleri (bağlantı izlenmez).
public struct FileDates: Sendable, Equatable {
    public var modified: Date?
    public var created: Date?

    public init(modified: Date?, created: Date?) {
        self.modified = modified
        self.created = created
    }
}

public protocol FileDatesProviding: Sendable {
    func dates(_ url: URL) -> FileDates?
}

public struct LiveFileDates: FileDatesProviding {
    public init() {}

    public func dates(_ url: URL) -> FileDates? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        func date(_ t: timespec) -> Date {
            Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9)
        }
        return FileDates(modified: date(st.st_mtimespec), created: date(st.st_birthtimespec))
    }
}

/// Git deposu bilgisi.
public struct GitInfo: Sendable, Equatable {
    public var remoteURL: String?
    /// Kök commit(ler)in en eskisi; aynı depo kopyasını tanımak için.
    public var firstCommit: String?
    /// Commit edilmemiş değişiklik var mı?
    public var isDirty: Bool
    /// Hiçbir remote'ta olmayan commit var mı? (upstream yoksa da yerel commit'ler sayılır)
    public var hasUnpushedCommits: Bool

    public init(remoteURL: String?, firstCommit: String?, isDirty: Bool, hasUnpushedCommits: Bool) {
        self.remoteURL = remoteURL
        self.firstCommit = firstCommit
        self.isDirty = isDirty
        self.hasUnpushedCommits = hasUnpushedCommits
    }

    /// Eşsiz içerik var mı? (TESPITLER ders 5)
    public var hasUniqueWork: Bool { isDirty || hasUnpushedCommits }
}

/// Bütün git çağrılarının ortak argümanları: depo ayarındaki fsmonitor komutu ve kancalar çalışmaz,
/// isteğe bağlı kilit dosyaları yazılmaz. (Sistem ayarı `GIT_CONFIG_NOSYSTEM` ile `Signals.live`'da kapatılır.)
public enum GitCommand {
    public static let safetyArguments = [
        "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "--no-optional-locks",
    ]

    public static func arguments(repo: String, _ args: [String]) -> [String] {
        safetyArguments + ["-C", repo] + args
    }

    /// Git alt süreçleri için ortam: sistem ayarı okunmaz, parola sorulmaz.
    public static let environment = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"]
}

public protocol GitInfoProviding: Sendable {
    /// `repo` bir git çalışma ağacı değilse ya da git yoksa nil.
    func info(repo: URL) async -> GitInfo?
}

/// `git` komutuyla gerçek uygulama. Bulut köklerindeki depolara girmez (git status dosya içeriği okuyabilir).
public struct LiveGitInfo: GitInfoProviding {
    public let runner: any CommandRunning
    public let cloudGuard: CloudGuard?

    public init(runner: any CommandRunning, cloudGuard: CloudGuard?) {
        self.runner = runner
        self.cloudGuard = cloudGuard
    }

    public func info(repo: URL) async -> GitInfo? {
        if let cloudGuard, !cloudGuard.isSafeForGit(repo) { return nil }
        func git(_ args: [String]) async -> CommandResult? {
            await runner.run("git", GitCommand.arguments(repo: repo.path, args), timeout: .seconds(20))
        }
        guard let top = await git(["rev-parse", "--is-inside-work-tree"]), top.succeeded,
              top.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        else { return nil }

        let remote = await git(["remote", "get-url", "origin"])
        let roots = await git(["rev-list", "--max-parents=0", "HEAD"])
        let status = await git(["status", "--porcelain"])
        let unpushed = await git(["rev-list", "--count", "--branches", "--not", "--remotes"])

        func trimmed(_ r: CommandResult?) -> String? {
            guard let r, r.succeeded else { return nil }
            let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        let unpushedCount = Int(trimmed(unpushed) ?? "0") ?? 0
        return GitInfo(
            remoteURL: trimmed(remote),
            firstCommit: trimmed(roots)?.split(separator: "\n").last.map(String.init),
            // status başarısızsa temkinli: kirli say.
            isDirty: status.map { !$0.succeeded || !$0.stdout.isEmpty } ?? true,
            hasUnpushedCommits: unpushedCount > 0
        )
    }
}

/// Tarayıcıların kullandığı sinyal sağlayıcıları. Testte sahteleri verilir.
public struct Signals: Sendable {
    public var commands: any CommandRunning
    public var processes: any ProcessListing
    public var spotlight: any SpotlightProviding
    public var fileDates: any FileDatesProviding
    public var git: any GitInfoProviding

    public init(
        commands: any CommandRunning,
        processes: any ProcessListing,
        spotlight: any SpotlightProviding,
        fileDates: any FileDatesProviding,
        git: any GitInfoProviding
    ) {
        self.commands = commands
        self.processes = processes
        self.spotlight = spotlight
        self.fileDates = fileDates
        self.git = git
    }

    public static func live(cloudGuard: CloudGuard) -> Signals {
        let runner = ProcessCommandRunner(environment: GitCommand.environment)
        return Signals(
            commands: runner,
            processes: LiveProcessLister(),
            spotlight: LiveSpotlight(),
            fileDates: LiveFileDates(),
            git: LiveGitInfo(runner: runner, cloudGuard: cloudGuard)
        )
    }

    /// Spotlight son açılış varsa `.opened`, yoksa değişiklik tarihi `.modified`, o da yoksa `.unknown`.
    public func dateSignal(for url: URL, now: Date) -> DateSignal {
        if let used = spotlight.lastUsedDate(url) { return .opened(days: DateSignal.days(from: used, to: now)) }
        if let m = fileDates.dates(url)?.modified { return .modified(days: DateSignal.days(from: m, to: now)) }
        return .unknown
    }
}
