import CryptoKit
import Foundation

/// Öğenin risk sınıfı. Varsayılan seçim yalnız `.green` ve kilitsiz öğelerdir.
public enum Risk: String, Codable, Sendable, CaseIterable, Comparable {
    /// Kendini yeniden oluşturur.
    case green
    /// Yeniden indirilir.
    case yellow
    /// Kullanıcı verisi ya da karar kullanıcıda.
    case red
    /// Kullanımda; seçilemez, taşınamaz.
    case locked
    /// Yalnız bilgi; taşınamaz.
    case info

    private var order: Int {
        switch self {
        case .green: 0
        case .yellow: 1
        case .red: 2
        case .locked: 3
        case .info: 4
        }
    }

    public static func < (lhs: Risk, rhs: Risk) -> Bool { lhs.order < rhs.order }
}

/// Tarayıcı kategorileri. CLI `--category` bu ham değerleri kullanır.
public enum Category: String, Codable, Sendable, CaseIterable {
    case xcode
    case projectArtifacts
    case caches
    case docker
    case oldVersions
    case largeOld
    case duplicates
    case folders
    case apps
}

/// `Category` Foundation'daki adla çakışabildiği için arayüzde kullanılacak takma ad.
public typealias ItemCategory = Category

/// Tarih sinyali. "Açıldı" (Spotlight son kullanım) ile "değişti" (dosya tarihi) ayrı gösterilir.
public enum DateSignal: Codable, Sendable, Equatable {
    case opened(days: Int)
    case modified(days: Int)
    case unknown

    public var days: Int? {
        switch self {
        case .opened(let d), .modified(let d): d
        case .unknown: nil
        }
    }

    /// Şimdiki zamana göre gün farkı (negatifse 0).
    public static func days(from date: Date, to now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 86_400))
    }
}

/// Temizleme yöntemi.
public enum CleanMethod: Sendable, Equatable {
    /// `FileManager.trashItem` ile Çöp Kutusu'na taşınır.
    case trash
    /// Kabuk komutu çalıştırılır (ör. `npm cache clean --force`). Kalıcı silme yalnız bu yoldan olur.
    case command(String)
    /// Temizlenemez (bilgi amaçlı).
    case none
}

extension CleanMethod: Codable {
    private enum CodingKeys: String, CodingKey { case kind, command }

    public init(from decoder: any Decoder) throws {
        // Kısa biçim: "trash" / "none"
        if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            switch s {
            case "trash": self = .trash
            case "none": self = .none
            default:
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "Bilinmeyen yöntem: \(s)")
            }
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "trash": self = .trash
        case "none": self = .none
        case "command": self = .command(try c.decode(String.self, forKey: .command))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Bilinmeyen yöntem: \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .trash: try c.encode("trash", forKey: .kind)
        case .none: try c.encode("none", forKey: .kind)
        case .command(let cmd):
            try c.encode("command", forKey: .kind)
            try c.encode(cmd, forKey: .command)
        }
    }
}

/// Temizlenebilir aday.
public struct CleanItem: Codable, Sendable, Identifiable, Equatable {
    /// Yol tabanlı stabil kimlik (`CleanItem.makeID(path:)`).
    public var id: String
    public var category: Category
    public var name: String
    /// Mutlak yol.
    public var path: String
    /// Diskte ayrılan boyut (bayt). Görünen boyut değil.
    public var allocatedBytes: UInt64
    public var risk: Risk
    public var dateSignal: DateSignal
    /// Doluysa öğe kilitlidir; seçilemez ve taşınamaz.
    public var lockReason: String?
    public var note: String?
    public var method: CleanMethod
    /// Öğeyle birlikte taşınan ek yollar (yalnız `apps`: bundle id ile tam eşleşen `~/Library` artıkları).
    /// Diğer kategorilerde nil; `Trasher` başka kategoride dolu gelirse öğeyi reddeder.
    public var relatedPaths: [String]?
    /// `false`: risk yeşil olsa bile varsayılan seçimde değil (ör. 30 günden yeni proje artığı). nil/true: risk kuralı.
    public var preselect: Bool?
    /// Yalnız `duplicates`: aynı içerikli kopyaların grup kimliği.
    public var groupID: String?
    /// Yalnız `duplicates`: grubun tutulacak kopyasının yolu (bu öğenin kendisi de olabilir).
    public var keeperPath: String?
    /// Yalnız `apps`: paket macOS Uygulama Yönetimi koruması ya da root sahipliği yüzünden kullanıcı yetkisiyle
    /// taşınamıyor; dar istisnanın diğer bütün koşullarını sağlıyor. Yalnız yetkili taşıyıcı (`NSWorkspace.recycle`,
    /// macOS parola/Touch ID ister) ile taşınabilir. Varsayılan seçimde değildir. nil/false: gerekmiyor.
    public var needsAuthorization: Bool?
    /// Yalnız `duplicates` tutulacak kopyasında: kullanıcı başka kopyayı tutarsa bu kopyanın riski
    /// (tarayıcının tutulmayan kopyaya vereceği risk). nil: bilinmiyor (sarı sayılır).
    public var ifNotKeptRisk: Risk?
    /// Yalnız `duplicates` tutulacak kopyasında: kullanıcı başka kopyayı tutarsa bu kopyanın kilit nedeni
    /// (ör. git'te takipli). Doluysa bu kopya yine taşınamaz.
    public var ifNotKeptLockReason: String?

    public init(
        category: Category,
        name: String,
        path: String,
        allocatedBytes: UInt64,
        risk: Risk,
        dateSignal: DateSignal = .unknown,
        lockReason: String? = nil,
        note: String? = nil,
        method: CleanMethod = .trash,
        relatedPaths: [String]? = nil,
        preselect: Bool? = nil,
        groupID: String? = nil,
        keeperPath: String? = nil,
        needsAuthorization: Bool? = nil
    ) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        self.id = CleanItem.makeID(path: standardized)
        self.category = category
        self.name = name
        self.path = standardized
        self.allocatedBytes = allocatedBytes
        self.risk = lockReason != nil ? .locked : risk
        self.dateSignal = dateSignal
        self.lockReason = lockReason
        self.note = note
        self.method = method
        let related = relatedPaths?.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? []
        self.relatedPaths = related.isEmpty ? nil : related
        self.preselect = preselect
        self.groupID = groupID
        self.keeperPath = keeperPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        self.needsAuthorization = needsAuthorization
    }

    public var url: URL { URL(fileURLWithPath: path) }

    public var isLocked: Bool { risk == .locked || lockReason != nil }

    /// Varsayılan seçim: yalnız yeşil, kilitsiz, temizlenebilir ve `preselect` ile kapatılmamış öğeler.
    public var isDefaultSelected: Bool {
        risk == .green && !isLocked && method != .none && preselect != false && needsAuthorization != true
    }

    /// Tutulacak mükerrer kopya mı?
    public var isDuplicateKeeper: Bool { groupID != nil && keeperPath == path }

    /// Öğenin diskte kapladığı yollar: kendi yolu + ilişkili yollar (uygulama artıkları).
    public var footprint: [String] { [path] + (relatedPaths ?? []) }

    /// Aynı yol her taramada aynı id'yi verir: standart yolun SHA-256 özetinin ilk 12 hex karakteri.
    public static func makeID(path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(standardized.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Öğeyi kilitler (risk `.locked` olur).
    public func locked(_ reason: String) -> CleanItem {
        var copy = self
        copy.lockReason = reason
        copy.risk = .locked
        return copy
    }
}
