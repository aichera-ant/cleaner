import Darwin
import Foundation

/// Kilit koşulu. Koşul sağlanırsa öğe kilitlenir.
public enum LockCondition: Codable, Sendable, Equatable {
    /// Ağaçtaki en yeni değişiklik son N saat içindeyse.
    case modifiedWithin(hours: Double)
    /// Adı verilen süreç ya da uygulama çalışıyorsa (`ProcessListing.isRunning`).
    case processRunning(name: String)

    private enum CodingKeys: String, CodingKey { case type, hours, name }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "modifiedWithin": self = .modifiedWithin(hours: try c.decode(Double.self, forKey: .hours))
        case "processRunning": self = .processRunning(name: try c.decode(String.self, forKey: .name))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Bilinmeyen kilit: \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .modifiedWithin(let h):
            try c.encode("modifiedWithin", forKey: .type)
            try c.encode(h, forKey: .hours)
        case .processRunning(let n):
            try c.encode("processRunning", forKey: .type)
            try c.encode(n, forKey: .name)
        }
    }
}

/// Bilinen bir yol için kural (`Resources/rules.json`).
public struct Rule: Codable, Sendable, Equatable {
    public var id: String
    /// `~/` ile başlar; bileşenlerde `*`, `?`, `[...]` glob desteklenir (bir bileşen içinde, `/` geçmez).
    public var path: String
    public var category: Category
    public var risk: Risk
    /// Kısa ad (listede görünür).
    public var name: String
    public var description: String
    public var method: CleanMethod
    public var locks: [LockCondition]

    public init(id: String, path: String, category: Category, risk: Risk, name: String, description: String,
                method: CleanMethod = .trash, locks: [LockCondition] = []) {
        self.id = id
        self.path = path
        self.category = category
        self.risk = risk
        self.name = name
        self.description = description
        self.method = method
        self.locks = locks
    }

    private enum CodingKeys: String, CodingKey { case id, path, category, risk, name, description, method, locks }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        category = try c.decode(Category.self, forKey: .category)
        risk = try c.decode(Risk.self, forKey: .risk)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        method = try c.decodeIfPresent(CleanMethod.self, forKey: .method) ?? .trash
        locks = try c.decodeIfPresent([LockCondition].self, forKey: .locks) ?? []
    }
}

public struct RuleSet: Codable, Sendable {
    public var version: Int
    public var rules: [Rule]

    public enum LoadError: Error, CustomStringConvertible {
        case missingResource
        case invalid(String)

        public var description: String {
            switch self {
            case .missingResource: "rules.json paket kaynağı bulunamadı"
            case .invalid(let m): "rules.json geçersiz: \(m)"
            }
        }
    }

    /// JSON'dan yükler ve doğrular.
    public static func decode(_ data: Data) throws -> RuleSet {
        let set = try JSONDecoder().decode(RuleSet.self, from: data)
        try set.validate()
        return set
    }

    /// Paket kaynağı `rules.json`. (Bu, `SafeReader` dışındaki tek dosya okumasıdır: kendi paket kaynağımız.)
    public static func loadBundled() throws -> RuleSet {
        guard let url = Bundle.module.url(forResource: "rules", withExtension: "json") else {
            throw LoadError.missingResource
        }
        return try decode(Data(contentsOf: url))
    }

    public func validate() throws {
        var ids = Set<String>()
        for r in rules {
            guard ids.insert(r.id).inserted else { throw LoadError.invalid("tekrarlanan id \(r.id)") }
            guard r.path.hasPrefix("~/") else { throw LoadError.invalid("\(r.id): yol ~/ ile başlamalı") }
            guard !r.path.split(separator: "/").contains(where: { $0 == ".." || $0 == "**" }) else {
                throw LoadError.invalid("\(r.id): '..' ve '**' kullanılamaz")
            }
            if case .command(let cmd) = r.method, cmd.trimmingCharacters(in: .whitespaces).isEmpty {
                throw LoadError.invalid("\(r.id): boş komut")
            }
        }
    }
}

/// `~` açılımı ve bileşen içi glob.
public enum PathExpander {
    public static func expand(_ path: String, home: URL) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appending(path: String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }

    static func hasGlob(_ s: Substring) -> Bool {
        s.contains("*") || s.contains("?") || s.contains("[")
    }

    /// Kalıba uyan var olan yolları döner (yalnız klasör listeleme, içerik okunmaz).
    /// Gizli girdiler yalnız kalıp bileşeni `.` ile başlıyorsa eşleşir.
    public static func glob(_ pattern: String, home: URL, fileManager: FileManager = .default) -> [URL] {
        let expanded = expand(pattern, home: home).path
        let components = expanded.split(separator: "/", omittingEmptySubsequences: true)
        var current: [String] = ["/"]
        for comp in components {
            var next: [String] = []
            for base in current {
                let prefix = base == "/" ? "/" : base + "/"
                if hasGlob(comp) {
                    guard let names = try? fileManager.contentsOfDirectory(atPath: base) else { continue }
                    for name in names.sorted() where fnmatch(String(comp), name, FNM_PERIOD) == 0 {
                        next.append(prefix + name)
                    }
                } else {
                    next.append(prefix + comp)
                }
            }
            current = next
            if current.isEmpty { return [] }
        }
        return current.filter { p in
            var st = stat()
            return lstat(p, &st) == 0
        }.map { URL(fileURLWithPath: $0) }
    }
}
