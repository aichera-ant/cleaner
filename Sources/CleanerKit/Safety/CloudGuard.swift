import Darwin
import Foundation

/// Bulut koruması: bir dosyanın İÇERİĞİNİ okumak güvenli mi?
///
/// Yalnız bulutta duran (dataless) bir dosyayı okumak onu Mac'e indirir ve diski doldurur
/// (TESPITLER.md, tasarım dersi 8). İçerik okuyan her kod `SafeReader` üzerinden bu kontrolden geçer.
///
/// Güvensiz sayılanlar:
/// - `~/Library/Mobile Documents` ve `~/Library/CloudStorage` altı (varsayılan kapalı),
/// - `SF_DATALESS` bayrağı taşıyan dosya,
/// - iCloud öğesi olup indirme durumu `.current` olmayan dosya,
/// - normal dosya olmayan her şey (bağlantı, klasör, aygıt).
public struct CloudGuard: Sendable {
    public enum Rejection: Error, Equatable, CustomStringConvertible, Sendable {
        case cloudRoot(String)
        case dataless(String)
        case notDownloaded(String)
        case notRegularFile(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .cloudRoot(let p): "bulut klasörü altında, içerik okunmaz: \(p)"
            case .dataless(let p): "yalnız bulutta (dataless), içerik okunmaz: \(p)"
            case .notDownloaded(let p): "iCloud dosyası indirilmemiş, içerik okunmaz: \(p)"
            case .notRegularFile(let p): "normal dosya değil: \(p)"
            case .unreadable(let p): "okunamadı: \(p)"
            }
        }
    }

    /// Test için enjekte edilebilir kontroller.
    public struct Probes: Sendable {
        /// Dosya dataless mı? (gerçek: `lstat` + `SF_DATALESS`)
        public var isDataless: @Sendable (URL) -> Bool
        /// iCloud öğesiyse indirme durumu `.current` mı? iCloud öğesi değilse nil.
        public var isDownloadedCurrent: @Sendable (URL) -> Bool?
        /// Normal dosya mı? (bağlantı izlenmez)
        public var isRegularFile: @Sendable (URL) -> Bool

        public init(
            isDataless: @escaping @Sendable (URL) -> Bool,
            isDownloadedCurrent: @escaping @Sendable (URL) -> Bool?,
            isRegularFile: @escaping @Sendable (URL) -> Bool
        ) {
            self.isDataless = isDataless
            self.isDownloadedCurrent = isDownloadedCurrent
            self.isRegularFile = isRegularFile
        }

        public static let live = Probes(
            isDataless: { CloudGuard.hasDatalessFlag(path: $0.path) },
            isDownloadedCurrent: { url in
                let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
                guard let v = try? url.resourceValues(forKeys: keys), v.isUbiquitousItem == true else { return nil }
                return v.ubiquitousItemDownloadingStatus == .current
            },
            isRegularFile: { url in
                var st = stat()
                guard lstat(url.path, &st) == 0 else { return false }
                return (st.st_mode & S_IFMT) == S_IFREG
            }
        )
    }

    public let home: URL
    /// Bulut köklerinde içerik okumaya izin. Varsayılan kapalı; açmak bilinçli bir karar olmalı.
    public let allowCloudRoots: Bool
    public let probes: Probes
    private let cloudRootKeys: [String]

    public init(home: URL, allowCloudRoots: Bool = false, probes: Probes = .live) {
        self.home = home
        self.allowCloudRoots = allowCloudRoots
        self.probes = probes
        let h = PathUtil.canonicalDirectory(home)
        self.cloudRootKeys = CloudGuard.cloudRootSuffixes.map { PathUtil.key(h + "/" + $0) }
    }

    static let cloudRootSuffixes = ["Library/Mobile Documents", "Library/CloudStorage"]

    /// Yol iCloud Drive ya da CloudStorage altında mı?
    public func isUnderCloudRoot(_ url: URL) -> Bool {
        let k = PathUtil.key(PathUtil.canonical(url))
        return cloudRootKeys.contains { PathUtil.isSameOrDescendant(k, of: $0) }
    }

    /// İçerik okumak güvenliyse döner, değilse `Rejection` fırlatır. Kendisi içerik okumaz.
    public func checkContentReadable(_ url: URL) throws(Rejection) {
        let path = url.standardizedFileURL.path
        if !allowCloudRoots && isUnderCloudRoot(url) { throw .cloudRoot(path) }
        if probes.isDataless(url) { throw .dataless(path) }
        if let current = probes.isDownloadedCurrent(url), !current { throw .notDownloaded(path) }
        if !probes.isRegularFile(url) { throw .notRegularFile(path) }
    }

    /// İçerik okumak güvenli mi? (Hata ayrıntısı gerekmezse.)
    public func isContentReadable(_ url: URL) -> Bool {
        do { try checkContentReadable(url); return true } catch { return false }
    }

    /// Bu klasörde git çalıştırmak güvenli mi? Git dosya içeriği okur (status, ls-files); alt süreç
    /// `IOPOL_MATERIALIZE_DATALESS_FILES_OFF` ayarını devralsa da (denendi: posix_spawn ve fork+exec devralır)
    /// bulut deposunda git hiç çalıştırılmaz. Güvensiz: bulut kökü altı, iCloud öğesi, kök ya da `.git` dataless.
    public func isSafeForGit(_ repo: URL) -> Bool {
        if isUnderCloudRoot(repo) { return false }
        let git = repo.appending(path: ".git")
        for u in [repo, git] {
            if probes.isDataless(u) { return false }
            if probes.isDownloadedCurrent(u) != nil { return false } // iCloud (ubiquitous) öğesi
        }
        return true
    }

    /// `lstat` ile `SF_DATALESS` bayrağı. Bağlantı izlenmez, içerik okunmaz.
    public static func hasDatalessFlag(path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_flags & UInt32(SF_DATALESS)) != 0
    }

    /// Bu süreçte dataless dosyaların okunarak indirilmesini çekirdek düzeyinde kapatır
    /// (`IOPOL_MATERIALIZE_DATALESS_FILES_OFF`). Kapatıldığında böyle bir dosyayı okumak indirme yerine
    /// hata verir. `CloudGuard` kontrolüne ek ikinci savunma hattıdır; CLI ve uygulama açılışta çağırır.
    @discardableResult
    public static func disableDatalessMaterializationForProcess() -> Bool {
        setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_PROCESS,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        ) == 0
    }
}
