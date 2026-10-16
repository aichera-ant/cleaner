import Foundation

/// Komut sonucu.
public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String = "", timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

/// Dış komut çalıştırıcı. Araç yoksa hata yerine `nil` döner (tarayıcı sessizce boş döner).
public protocol CommandRunning: Sendable {
    /// `tool`: çalıştırılabilir ad (PATH'te aranır) ya da mutlak yol.
    func run(_ tool: String, _ arguments: [String], timeout: Duration) async -> CommandResult?
    /// Kabuk komutu (`/bin/zsh -l -c`). Yalnız kural dosyası ve tarayıcıların ürettiği sabit komutlar için.
    func runShell(_ command: String, timeout: Duration) async -> CommandResult?
}

extension CommandRunning {
    public func run(_ tool: String, _ arguments: [String]) async -> CommandResult? {
        await run(tool, arguments, timeout: .seconds(30))
    }
}

/// `Process` ile gerçek uygulama. Zaman aşımında süreç sonlandırılır.
public struct ProcessCommandRunner: CommandRunning {
    /// GUI uygulamalarında PATH kısa olur; bilinen kurulum yerleri eklenir.
    public static let extraSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    public var environment: [String: String]?

    public init(environment: [String: String]? = nil) {
        self.environment = environment
    }

    public func resolve(_ tool: String) -> String? {
        let fm = FileManager.default
        if tool.contains("/") { return fm.isExecutableFile(atPath: tool) ? tool : nil }
        let envPath = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for dir in envPath + Self.extraSearchPaths {
            let candidate = dir + "/" + tool
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public func run(_ tool: String, _ arguments: [String], timeout: Duration) async -> CommandResult? {
        guard let exe = resolve(tool) else { return nil }
        return await Self.execute(executable: exe, arguments: arguments, environment: environment, timeout: timeout)
    }

    public func runShell(_ command: String, timeout: Duration) async -> CommandResult? {
        await Self.execute(executable: "/bin/zsh", arguments: ["-l", "-c", command], environment: environment, timeout: timeout)
    }

    static func execute(executable: String, arguments: [String], environment: [String: String]?, timeout: Duration) async -> CommandResult? {
        await withCheckedContinuation { (cont: CheckedContinuation<CommandResult?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: executeBlocking(executable: executable, arguments: arguments, environment: environment, timeout: timeout))
            }
        }
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var out = Data()
        var err = Data()
        var timedOut = false
        /// Süreç bitti ve toplandı: bundan sonra pid'e sinyal gönderilmez (pid yeniden kullanılmış olabilir).
        var exited = false
    }

    private static func executeBlocking(executable: String, arguments: [String], environment: [String: String]?, timeout: Duration) -> CommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let box = Box()
        let group = DispatchGroup()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        group.enter()
        DispatchQueue.global().async {
            let d = outHandle.readDataToEndOfFile()
            box.lock.lock(); box.out = d; box.lock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let d = errHandle.readDataToEndOfFile()
            box.lock.lock(); box.err = d; box.lock.unlock()
            group.leave()
        }

        let pid = process.processIdentifier
        // Sinyal yalnız süreç henüz toplanmamışken ve kilit altında gönderilir: `waitUntilExit` sonrası
        // `exited` true olur, gecikmiş SIGKILL yeniden kullanılmış bir pid'e gitmez.
        func signal(_ sig: Int32, markTimeout: Bool) {
            box.lock.lock(); defer { box.lock.unlock() }
            guard !box.exited else { return }
            if markTimeout { box.timedOut = true }
            kill(pid, sig)
        }
        let killer = DispatchWorkItem { signal(SIGKILL, markTimeout: false) }
        let timer = DispatchWorkItem {
            signal(SIGTERM, markTimeout: true)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: killer)
        }
        let comps = timeout.components
        let seconds = Double(comps.seconds) + Double(comps.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)

        process.waitUntilExit()
        box.lock.lock(); box.exited = true; box.lock.unlock()
        timer.cancel()
        killer.cancel()
        // Torun süreç boruyu açık tutarsa sonsuza dek beklememek için sınırlı bekle.
        _ = group.wait(timeout: .now() + 5)

        box.lock.lock(); defer { box.lock.unlock() }
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: box.out, as: UTF8.self),
            stderr: String(decoding: box.err, as: UTF8.self),
            timedOut: box.timedOut
        )
    }
}
