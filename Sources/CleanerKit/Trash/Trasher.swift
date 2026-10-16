import Foundation

/// Çöp Kutusu raporu.
public struct TrashReport: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        /// Çöp Kutusu'na taşındı (dry-run'da: taşınacaktı).
        case trashed
        /// Komut çalıştırıldı (dry-run'da: çalıştırılacaktı).
        case command
    }

    public struct Done: Codable, Sendable, Equatable {
        public var id: String
        public var path: String
        public var bytes: UInt64
        public var action: Action
        /// Çöp Kutusu'ndaki yeni yol ya da komut çıktısı özeti.
        public var detail: String?
    }

    public struct Refused: Codable, Sendable, Equatable {
        public var id: String
        public var path: String
        public var reason: String

        public init(id: String, path: String, reason: String) {
            self.id = id
            self.path = path
            self.reason = reason
        }
    }

    public var dryRun: Bool
    public var done: [Done]
    public var refused: [Refused]

    public var totalBytes: UInt64 { done.reduce(0) { $0 &+ $1.bytes } }
}

/// Seçilen öğeleri Çöp Kutusu'na taşır ya da komutlarını çalıştırır. Kalıcı silme yapmaz.
///
/// Reddedilenler: kilitli öğe, `.info` risk, `.none` yöntem, korunan yol, ana klasör dışı, git deposu kökü,
/// var olmayan yol. Varsayılan dry-run: hiçbir şey taşınmaz, yalnız rapor üretilir.
public struct Trasher: Sendable {
    public let policy: PathPolicy
    public let commands: any CommandRunning
    public var commandTimeout: Duration
    /// Taşıma işlemi. Gerçekte `FileManager.trashItem`; testte geçici klasöre taşıyan sahte verilir
    /// (gerçek Çöp Kutusu'na dokunulmasın diye).
    let mover: @Sendable (URL) throws -> URL?

    public init(policy: PathPolicy, commands: any CommandRunning, commandTimeout: Duration = .seconds(600)) {
        self.init(policy: policy, commands: commands, commandTimeout: commandTimeout, mover: Trasher.systemTrash)
    }

    init(policy: PathPolicy, commands: any CommandRunning, commandTimeout: Duration = .seconds(600),
         mover: @escaping @Sendable (URL) throws -> URL?) {
        self.policy = policy
        self.commands = commands
        self.commandTimeout = commandTimeout
        self.mover = mover
    }

    static let systemTrash: @Sendable (URL) throws -> URL? = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// Öğe neden reddedilir? Reddedilmiyorsa nil.
    public func rejectionReason(for item: CleanItem) -> String? {
        if item.isLocked { return "kilitli: \(item.lockReason ?? "kullanımda")" }
        if item.risk == .info { return "yalnız bilgi" }
        if item.method == .none { return "temizleme yöntemi yok" }
        // Öğe kimliği yoluyla tutarlı olmalı (elle değiştirilmiş öğe ile başka yol taşınmasın).
        if item.id != CleanItem.makeID(path: item.path) { return "id ile yol uyuşmuyor" }
        return policy.trashRejectionReason(for: item.url)
    }

    public func trash(_ items: [CleanItem], dryRun: Bool = true) async -> TrashReport {
        var report = TrashReport(dryRun: dryRun, done: [], refused: [])
        var handled = Set<String>()
        for item in items {
            guard handled.insert(item.id).inserted else { continue }
            if let reason = rejectionReason(for: item) {
                report.refused.append(.init(id: item.id, path: item.path, reason: reason))
                continue
            }
            switch item.method {
            case .none:
                continue // rejectionReason yakalar
            case .command(let cmd):
                if dryRun {
                    report.done.append(.init(id: item.id, path: item.path, bytes: item.allocatedBytes, action: .command, detail: cmd))
                    continue
                }
                guard let result = await commands.runShell(cmd, timeout: commandTimeout) else {
                    report.refused.append(.init(id: item.id, path: item.path, reason: "komut çalıştırılamadı: \(cmd)"))
                    continue
                }
                if result.succeeded {
                    report.done.append(.init(id: item.id, path: item.path, bytes: item.allocatedBytes, action: .command, detail: cmd))
                } else {
                    let why = result.timedOut ? "zaman aşımı" : "çıkış kodu \(result.exitCode)"
                    report.refused.append(.init(id: item.id, path: item.path, reason: "komut başarısız (\(why)): \(cmd)"))
                }
            case .trash:
                if dryRun {
                    report.done.append(.init(id: item.id, path: item.path, bytes: item.allocatedBytes, action: .trashed, detail: nil))
                    continue
                }
                // Taşımadan hemen önce son kontrol (tarama ile taşıma arasında yol değişmiş olabilir).
                if let reason = policy.trashRejectionReason(for: item.url) {
                    report.refused.append(.init(id: item.id, path: item.path, reason: reason))
                    continue
                }
                do {
                    let resulting = try mover(item.url)
                    report.done.append(.init(id: item.id, path: item.path, bytes: item.allocatedBytes, action: .trashed, detail: resulting?.path))
                } catch {
                    report.refused.append(.init(id: item.id, path: item.path, reason: "taşınamadı: \(error.localizedDescription)"))
                }
            }
        }
        return report
    }
}
