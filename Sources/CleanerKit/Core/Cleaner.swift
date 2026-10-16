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
    func scan(_ context: ScanContext) async throws -> [CleanItem]
}

/// Tarama bağlamı: kökler, zaman, sinyaller, güvenlik API'leri.
public struct ScanContext: Sendable {
    /// Ana klasör. Testte geçici klasör verilir; `~` açılımı buna göre yapılır.
    public var home: URL
    /// Proje artıkları vb. için taranacak kökler.
    public var roots: [URL]
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
        roots: [URL],
        now: Date = Date(),
        signals: Signals,
        sizeMeter: SizeMeter = SizeMeter(),
        cloudGuard: CloudGuard? = nil,
        rules: [Rule] = []
    ) {
        self.home = home
        self.roots = roots
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
            roots: roots ?? defaultRoots(home: home),
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
