import Foundation
@testable import CleanerKit

/// Geçici klasör ağacı. Her şey `FileManager.default.temporaryDirectory` altında; bitince silinir.
final class TempTree: @unchecked Sendable {
    let root: URL
    /// Sahte ana klasör.
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "cleaner-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit {
        // İzinleri geri aç (izin testleri 000 yapabilir), sonra yalnız kendi geçici kökümüzü sil.
        if let e = FileManager.default.enumerator(atPath: root.path) {
            while let rel = e.nextObject() as? String {
                chmod(root.appending(path: rel).path, 0o755)
            }
        }
        precondition(root.path.contains("cleaner-tests-"))
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func dir(_ rel: String, in base: URL? = nil) throws -> URL {
        let u = (base ?? home).appending(path: rel, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    func file(_ rel: String, bytes: Int = 4096, in base: URL? = nil) throws -> URL {
        let u = (base ?? home).appending(path: rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: u)
        return u
    }

    func exists(_ u: URL) -> Bool {
        var st = stat()
        return lstat(u.path, &st) == 0
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _n = 0
    private var _log: [String] = []
    var n: Int { lock.withLock { _n } }
    var log: [String] { lock.withLock { _log } }
    func hit(_ s: String = "") { lock.withLock { _n += 1; _log.append(s) } }
}

struct FakeCommands: CommandRunning {
    var counter = Counter()
    var result: CommandResult? = CommandResult(exitCode: 0, stdout: "")

    func run(_ tool: String, _ arguments: [String], timeout: Duration) async -> CommandResult? {
        counter.hit(([tool] + arguments).joined(separator: " "))
        return result
    }

    func runShell(_ command: String, timeout: Duration) async -> CommandResult? {
        counter.hit(command)
        return result
    }
}

struct FakeProcesses: ProcessListing {
    var names: [String] = []
    func runningProcesses() -> [RunningProcess] {
        names.enumerated().map { RunningProcess(pid: Int32($0.offset + 100), name: $0.element, path: nil) }
    }
}

struct FakeSpotlight: SpotlightProviding {
    var dates: [String: Date] = [:]
    func lastUsedDate(_ url: URL) -> Date? { dates[url.path] }
}

struct FakeGit: GitInfoProviding {
    var infos: [String: GitInfo] = [:]
    func info(repo: URL) async -> GitInfo? { infos[repo.path] }
}

extension Signals {
    static func fake(
        commands: FakeCommands = FakeCommands(),
        processes: FakeProcesses = FakeProcesses(),
        spotlight: FakeSpotlight = FakeSpotlight(),
        git: FakeGit = FakeGit()
    ) -> Signals {
        Signals(commands: commands, processes: processes, spotlight: spotlight, fileDates: LiveFileDates(), git: git)
    }
}

extension ScanContext {
    static func test(_ tree: TempTree, now: Date = Date(), signals: Signals = .fake(), rules: [Rule] = [],
                     cloudGuard: CloudGuard? = nil) -> ScanContext {
        ScanContext(home: tree.home, roots: [tree.home], now: now, signals: signals, cloudGuard: cloudGuard, rules: rules)
    }
}
