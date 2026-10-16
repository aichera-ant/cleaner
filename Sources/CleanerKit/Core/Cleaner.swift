import Foundation

/// Bir kategori tarayıcısı. Her tarayıcı `Sources/CleanerKit/Scanners/` altında ayrı dosyadadır.
///
/// Sözleşme:
/// - Yalnız meta veri okur. Dosya İÇERİĞİ gerekiyorsa yalnız `context.safeReader` kullanılır.
/// - Boyut için `context.sizeMeter` kullanılır (ayrılan boyut).
/// - Kullanımdaki öğe `lockReason` ile kilitlenir.
/// - Korunan yol üretse bile `ScanEngine` onu atar; yine de üretmemeye çalışın.
/// - Araç yoksa (docker, xcrun ...) hata fırlatmaz, boş döner.
/// - Uzun döngülerde `try context.checkCancellation()` çağrılır.
public protocol Cleaner: Sendable {
    /// Kayıt ve hata raporu için kısa ad (ör. "rules", "xcode").
    var id: String { get }
    /// Bu tarayıcının üretebileceği kategoriler (`--category` süzgeci için).
    var categories: Set<Category> { get }
    /// Çalışma aşaması. 0: ilk aşama (paralel). 1: ilk aşama bittikten sonra, `context.claimedPaths`
    /// dolu olarak çalışır (ör. büyük ve eski: başka tarayıcının öğesini kapsayan klasörü aday yapmaz).
    var phase: Int { get }
    func scan(_ context: ScanContext) async throws -> [CleanItem]
}

extension Cleaner {
    public var phase: Int { 0 }
}

/// Tarama bağlamı: kökler, zaman, sinyaller, güvenlik API'leri.
public struct ScanContext: Sendable {
    /// Ana klasör. Testte geçici klasör verilir; `~` açılımı buna göre yapılır.
    public var home: URL
    /// Kullanıcının verdiği kökler (`--roots`). nil: her tarayıcı kendi varsayılanını kullanır.
    public var explicitRoots: [URL]?
    /// Proje artıkları ve klasörler için taranacak kökler: verilmişse onlar, yoksa `defaultRoots`.
    /// Atamak `explicitRoots`'u değiştirir.
    public var roots: [URL] {
        get { explicitRoots ?? ScanContext.defaultRoots(home: home) }
        set { explicitRoots = newValue }
    }
    /// Kök verilmemişse `fallback`, verilmişse verilen kökler (tarayıcıya özgü varsayılan için).
    public func roots(default fallback: [URL]) -> [URL] {
        explicitRoots ?? fallback
    }
    /// İlk aşamadaki tarayıcıların ürettiği öğelerin yolları (`PathUtil.key(PathUtil.canonical(...))`).
    /// Yalnız `phase >= 1` tarayıcılara dolu gelir.
    public var claimedPaths: Set<String> = []
    /// "Şimdi" (testte sabitlenir).
    public var now: Date
    public var signals: Signals
    public var sizeMeter: SizeMeter
    public var pathPolicy: PathPolicy
    public var cloudGuard: CloudGuard
    /// Dosya içeriği okumanın tek yolu.
    public var safeReader: SafeReader
    /// Yüklenmiş kurallar.
    public var rules: [Rule]

    public init(
        home: URL,
        roots: [URL]?,
        now: Date = Date(),
        signals: Signals,
        sizeMeter: SizeMeter = SizeMeter(),
        cloudGuard: CloudGuard? = nil,
        rules: [Rule] = []
    ) {
        self.home = home
        self.explicitRoots = roots
        self.now = now
        self.signals = signals
        self.sizeMeter = sizeMeter
        self.pathPolicy = PathPolicy(home: home)
        let guardian = cloudGuard ?? CloudGuard(home: home)
        self.cloudGuard = guardian
        self.safeReader = SafeReader(cloudGuard: guardian)
        self.rules = rules
    }

    /// Gerçek makine için bağlam.
    public static func live(roots: [URL]? = nil, rules: [Rule]? = nil) throws -> ScanContext {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let guardian = CloudGuard(home: home)
        return ScanContext(
            home: home,
            roots: roots,
            signals: .live(cloudGuard: guardian),
            cloudGuard: guardian,
            rules: try rules ?? RuleSet.loadBundled().rules
        )
    }

    public static func defaultRoots(home: URL) -> [URL] {
        [home.appending(path: "Documents/projeler"), home.appending(path: "Desktop")]
    }

    public func checkCancellation() throws {
        try Task.checkCancellation()
    }

    /// `~` ile başlayan yolu bu bağlamın ana klasörüne göre açar.
    public func expand(_ path: String) -> URL {
        PathExpander.expand(path, home: home)
    }
}

/// Kayıtlı tarayıcılar. Yeni tarayıcı eklemek: tipini yaz, ilgili `Registry+*.swift` dosyasındaki
/// `register...` fonksiyonuna tek satır ekle. Gruplar ayrı dosyada olduğu için paralel çalışan
/// geliştiriciler aynı dosyaya dokunmaz.
public struct CleanerRegistry: Sendable {
    public private(set) var cleaners: [any Cleaner] = []

    public init() {}

    public mutating func register(_ cleaner: any Cleaner) {
        precondition(!cleaners.contains { $0.id == cleaner.id }, "Aynı id ile iki tarayıcı: \(cleaner.id)")
        cleaners.append(cleaner)
    }

    /// Varsayılan küme: çekirdek + geliştirici grubu + dosya grubu.
    public static func makeDefault() -> CleanerRegistry {
        var r = CleanerRegistry()
        registerCoreScanners(&r)
        registerDeveloperScanners(&r)
        registerFileScanners(&r)
        return r
    }
}
