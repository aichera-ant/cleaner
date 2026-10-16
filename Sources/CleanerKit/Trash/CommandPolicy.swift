import Foundation

/// Komutla temizlenen öğelerin izin listesi. Komut hiçbir zaman öğedeki metinden çalıştırılmaz:
/// öğenin kategorisine ve yolundaki doğrulanmış kimliğe göre burada yeniden kurulur, öğedeki komutla
/// birebir karşılaştırılır, eşleşirse kurulan biçim çalıştırılır.
///
/// - `docker`: yol `/docker/<tür>/<kimlik>` sanal yoludur (diskte yok); Çöp Kutusu'na asla gitmez.
///   Kimlik `isSafeToken`; container ve imaj kimliği onaltılık. Komut kabuk olmadan (`docker` + argümanlar) çalışır.
/// - `xcode` simülatörü: yol `~/Library/Developer/CoreSimulator/Devices/<UDID>`, UDID UUID biçiminde.
///   (`simctl` `--` desteklemediği için eklenmez; UUID biçimi seçenek gibi okunamaz.)
/// - Kural komutları (`rules.json`): yalnız `ruleCommands` listesindeki kural id'si, yolu ve komutu;
///   öğe yolu kuralın yoluyla aynı olmalı. Kural dosyası listede olmayan komut taşıyamaz (`RuleSet.validate`).
public enum CommandPolicy {
    /// Çalıştırılacak biçim.
    public enum Exec: Sendable, Equatable {
        /// Kabuksuz: araç + argümanlar.
        case argv(String, [String])
        /// Giriş kabuğu (`zsh -l -c`): npm/pnpm gibi kullanıcı PATH'indeki araçlar için. Yalnız sabit metin.
        case shell(String)
    }

    /// Komutla temizlenen kurallar: id, yol ve komut birlikte izinlidir.
    public struct RuleCommand: Sendable, Equatable {
        public var ruleID: String
        public var path: String
        public var category: Category
        public var command: String
    }

    public static let ruleCommands: [RuleCommand] = [
        RuleCommand(ruleID: "npm-cache", path: "~/.npm", category: .caches, command: "npm cache clean --force"),
        RuleCommand(ruleID: "pnpm-store", path: "~/Library/pnpm/store", category: .caches, command: "pnpm store prune"),
    ]

    // MARK: - Docker

    public enum DockerKind: String, Sendable, CaseIterable {
        case container, image, volume
    }

    public static func dockerPath(_ kind: DockerKind, _ id: String) -> String { "/docker/\(kind.rawValue)/\(id)" }
    public static let dockerBuildCachePath = "/docker/build-cache"

    static func dockerArgs(_ kind: DockerKind, _ id: String) -> [String] {
        switch kind {
        case .container: ["rm", "--", id]
        case .image: ["rmi", "--", id]
        case .volume: ["volume", "rm", "--", id]
        }
    }

    static let dockerBuildCacheArgs = ["builder", "prune", "-f"]

    /// Tarayıcının öğeye yazdığı komut metni.
    public static func dockerCommand(_ kind: DockerKind, _ id: String) -> String {
        (["docker"] + dockerArgs(kind, id)).joined(separator: " ")
    }

    public static var dockerBuildCacheCommand: String { (["docker"] + dockerBuildCacheArgs).joined(separator: " ") }

    // MARK: - Simülatör

    static let simulatorDevicesRelative = "Library/Developer/CoreSimulator/Devices"

    public static func simulatorCommand(udid: String) -> String { "xcrun simctl delete \(udid)" }

    /// 8-4-4-4-12 onaltılık.
    public static func isUUID(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return parts.allSatisfy { $0.unicodeScalars.allSatisfy(isHexScalar) }
    }

    static func isHexScalar(_ c: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(c) || ("a"..."f").contains(c) || ("A"..."F").contains(c)
    }

    static func isHex(_ s: String) -> Bool { !s.isEmpty && s.unicodeScalars.allSatisfy(isHexScalar) }

    // MARK: - Doğrulama

    /// Öğenin komutu izinliyse çalıştırılacak biçimi, değilse ret nedenini döner. Yol var mı ve korunuyor mu
    /// (gerçek yollu öğelerde) burada denetlenir.
    public static func validate(_ item: CleanItem, policy: PathPolicy) -> Result<Exec, Rejection> {
        guard case .command(let cmd) = item.method else { return .failure(.init("komut yöntemi değil")) }
        if item.path.hasPrefix("/docker/") || item.path == "/docker" {
            return validateDocker(item, cmd)
        }
        switch item.category {
        case .xcode: return validateSimulator(item, cmd, policy: policy)
        default: return validateRuleCommand(item, cmd, policy: policy)
        }
    }

    public struct Rejection: Error, Sendable, Equatable {
        public var reason: String
        init(_ reason: String) { self.reason = reason }
    }

    static func validateDocker(_ item: CleanItem, _ cmd: String) -> Result<Exec, Rejection> {
        guard item.category == .docker else { return .failure(.init("docker yolu yalnız docker kategorisinde olabilir")) }
        if item.path == dockerBuildCachePath {
            guard cmd == dockerBuildCacheCommand else { return .failure(.init("komut izin listesinde değil: \(cmd)")) }
            return .success(.argv("docker", dockerBuildCacheArgs))
        }
        let parts = item.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // ["", "docker", tür, kimlik]
        guard parts.count == 4, parts[0].isEmpty, parts[1] == "docker",
              let kind = DockerKind(rawValue: parts[2]) else {
            return .failure(.init("docker yolu tanınmıyor"))
        }
        let id = parts[3]
        guard XcodeScanner.isSafeToken(id) else { return .failure(.init("docker kimliği güvenli değil")) }
        if kind != .volume, !isHex(id) { return .failure(.init("docker kimliği onaltılık değil")) }
        guard cmd == dockerCommand(kind, id) else { return .failure(.init("komut yoldaki kimlikle uyuşmuyor: \(cmd)")) }
        return .success(.argv("docker", dockerArgs(kind, id)))
    }

    static func validateSimulator(_ item: CleanItem, _ cmd: String, policy: PathPolicy) -> Result<Exec, Rejection> {
        let url = item.url
        let udid = url.lastPathComponent
        guard isUUID(udid) else { return .failure(.init("simülatör UDID'si geçersiz")) }
        let parent = PathUtil.key(PathUtil.canonical(url.deletingLastPathComponent()))
        let expected = PathUtil.key(PathUtil.canonicalDirectory(policy.home) + "/" + simulatorDevicesRelative)
        guard parent == expected else { return .failure(.init("simülatör klasörü CoreSimulator/Devices altında değil")) }
        guard cmd == simulatorCommand(udid: udid) else { return .failure(.init("komut yoldaki UDID ile uyuşmuyor: \(cmd)")) }
        if let why = policy.trashRejectionReason(for: url) { return .failure(.init(why)) }
        return .success(.argv("xcrun", ["simctl", "delete", udid]))
    }

    static func validateRuleCommand(_ item: CleanItem, _ cmd: String, policy: PathPolicy) -> Result<Exec, Rejection> {
        let itemKey = PathUtil.key(PathUtil.canonical(item.url))
        guard let rule = ruleCommands.first(where: { r in
            r.command == cmd && r.category == item.category
                && PathUtil.key(PathUtil.canonical(PathExpander.expand(r.path, home: policy.home))) == itemKey
        }) else {
            return .failure(.init("komut izin listesinde değil ya da yolu kuralla uyuşmuyor: \(cmd)"))
        }
        if let why = policy.trashRejectionReason(for: item.url) { return .failure(.init(why)) }
        return .success(.shell(rule.command))
    }
}
