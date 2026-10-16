import Foundation

/// Korunan yollar ve taşıma izni. Tek kaynak: hem tarama (öğe olabilir mi) hem Çöp Kutusu (taşınabilir mi)
/// bu tipten geçer.
///
/// Kurallar:
/// - Hiçbir zaman öğe olamaz: ana klasörün kendisi, standart kök klasörler (Belgeler, Masaüstü, İndirilenler,
///   Library, Library/Caches ...), iCloud ve CloudStorage altı, `~/Library/Keychains`, `~/.ssh`, `~/.gnupg`
///   altı, herhangi bir `.git` klasörü ve içi, sistem klasörleri, korunan bir yolu içeren her üst klasör.
/// - Taşınamaz: yukarıdakiler, ana klasör dışındaki her şey, doğrudan `.git` içeren klasör (git deposu kökü),
///   uygulama köklerinin (`/Applications`, `~/Applications`) altındaki her şey.
///
/// Tek dar istisna (karar, 2026-10-16): `apps` kategorisindeki öğe olarak, bir uygulama kökünün
/// DOĞRUDAN çocuğu olan gerçek `.app` paketi (`appBundleRejectionReason`) ve o paketin bundle id'siyle
/// tam eşleşen `~/Library` artıkları (`leftoverRejectionReason`). Çalışan, Apple ve Cleaner'ın kendisi
/// kontrolü `Trasher`'dadır. Başka hiçbir sistem yolu açılmaz.
public struct PathPolicy: Sendable {
    public let home: URL
    private let homeKey: String
    /// Uygulama kökleri (varsayılan `/Applications`, `~/Applications`). Testte geçici klasör verilir.
    public let appRoots: [URL]
    /// Uygulama köklerinin yazıldığı (standart, çözülmemiş) yollarının anahtarları.
    private let appRootLiteralKeys: [String]
    /// Uygulama köklerinin çözülmüş yollarının anahtarları (`appRootLiteralKeys` ile aynı sırada).
    private let appRootKeys: [String]
    /// Kendisi korunan (içindekiler öğe olabilir) yollar.
    private let exactKeys: Set<String>
    /// Kendisi ve altı tamamen korunan yollar.
    private let subtreeKeys: [String]

    /// Ana klasör dışındaki sistem yolları (kendisi ve altı).
    static let systemPrefixes = [
        "/system", "/library", "/usr", "/bin", "/sbin", "/etc", "/var", "/private",
        "/opt", "/cores", "/dev", "/volumes", "/network", "/applications", "/users",
    ]

    /// Ana klasöre göreli, kendisi korunan klasörler.
    static let homeExactRoots = [
        "Documents", "Desktop", "Downloads", "Pictures", "Music", "Movies", "Public",
        "Applications", "Library", "Library/Caches", "Library/Application Support",
        "Library/Containers", "Library/Group Containers", "Library/Preferences",
        "Library/Developer", "Library/Logs",
    ]

    /// Ana klasöre göreli, kendisi ve altı korunan klasörler.
    static let homeSubtreeRoots = [
        "Library/Mobile Documents", // iCloud Drive
        "Library/CloudStorage", // Dropbox, Google Drive, OneDrive ...
        "Library/Keychains",
        "Library/Mail",
        "Library/Messages",
        ".ssh",
        ".gnupg",
    ]

    public init(home: URL, appRoots: [URL]? = nil) {
        self.home = home
        let homeKey = PathUtil.key(PathUtil.canonicalDirectory(home))
        self.homeKey = homeKey
        self.exactKeys = Set(PathPolicy.homeExactRoots.map { PathUtil.key(homeKey + "/" + $0) } + [homeKey])
        self.subtreeKeys = PathPolicy.homeSubtreeRoots.map { PathUtil.key(homeKey + "/" + $0) }
        let roots = appRoots ?? PathPolicy.defaultAppRoots(home: home)
        self.appRoots = roots
        self.appRootLiteralKeys = roots.map { PathUtil.key($0.standardizedFileURL.path) }
        self.appRootKeys = roots.map { PathUtil.key(PathUtil.canonicalDirectory($0)) }
    }

    public static func defaultAppRoots(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appending(path: "Applications", directoryHint: .isDirectory)]
    }

    /// Uygulama artığı olabilecek klasörler (ana klasöre göreli) ve bu klasörde bundle id'den türeyen adlar.
    /// Grup kapsayıcıları `groupContainerMatches` ile ayrıca eşleşir.
    static let leftoverParents: [(String, @Sendable (String) -> [String])] = [
        ("Library/Application Support", { [$0] }),
        ("Library/Caches", { [$0] }),
        ("Library/Containers", { [$0] }),
        ("Library/Preferences", { [$0 + ".plist"] }),
        ("Library/Saved Application State", { [$0 + ".savedState"] }),
        ("Library/HTTPStorages", { [$0, $0 + ".binarycookies"] }),
        ("Library/WebKit", { [$0] }),
        ("Library/Logs", { [$0] }),
    ]
    static let groupContainersParent = "Library/Group Containers"

    /// Grup kapsayıcısı adı bu bundle id'ye mi ait? Yalnız `group.<id>` ya da `<TAKIM>.<id>` /
    /// `<TAKIM>.group.<id>` (TAKIM: 10 büyük harf/rakam). Paylaşılan grup (ör. `UBF8T346G9.Office`) eşleşmez.
    public static func groupContainerMatches(_ name: String, bundleID: String) -> Bool {
        let n = name.lowercased(), id = bundleID.lowercased()
        if n == "group." + id { return true }
        let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 10,
              parts[0].unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) })
        else { return false }
        let rest = parts[1].lowercased()
        return rest == id || rest == "group." + id
    }

    /// Yol (çözülmüş) bir uygulama kökünün altında mı (kökün kendisi hariç)?
    func isUnderAppRoot(_ key: String) -> Bool {
        appRootKeys.contains { key != $0 && PathUtil.isSameOrDescendant(key, of: $0) }
    }

    /// Yol ana klasörün altında mı (kendisi hariç)?
    public func isInsideHome(_ url: URL) -> Bool {
        let k = PathUtil.key(PathUtil.canonical(url))
        return k != homeKey && PathUtil.isSameOrDescendant(k, of: homeKey)
    }

    /// Yol hiçbir zaman öğe olmamalıysa nedenini döner, yoksa nil.
    public func protectionReason(for url: URL) -> String? {
        let canonical = PathUtil.canonical(url)
        let k = PathUtil.key(canonical)

        if k == homeKey { return "ana klasörün kendisi" }
        if exactKeys.contains(k) { return "korunan kök klasör" }
        if appRootKeys.contains(k) { return "uygulama klasörünün kendisi" }

        let components = k.split(separator: "/")
        if components.contains(".git") { return "git deposu içi (.git)" }

        for s in subtreeKeys where PathUtil.isSameOrDescendant(k, of: s) {
            return "korunan klasör: \(s)"
        }
        // Korunan bir yolu içeren üst klasör de korunur (ör. ~/Library, Keychains'i içerir).
        for s in subtreeKeys where PathUtil.isSameOrDescendant(s, of: k) {
            return "korunan klasörü içeriyor: \(s)"
        }
        for e in exactKeys where e != k && PathUtil.isSameOrDescendant(e, of: k) {
            return "korunan klasörü içeriyor: \(e)"
        }

        if !PathUtil.isSameOrDescendant(k, of: homeKey) {
            if k == "/" { return "sistem kökü" }
            // Uygulama kökleri altındakiler öğe olabilir (listelenir; taşıma yalnız `appBundleRejectionReason` ile).
            if isUnderAppRoot(k) { return nil }
            for p in PathPolicy.systemPrefixes where PathUtil.isSameOrDescendant(k, of: p) {
                // /Users altında ana klasör dışı: başka kullanıcı.
                return "sistem klasörü"
            }
        }
        return nil
    }

    /// Yol Çöp Kutusu'na taşınamıyorsa nedenini döner. Taşımadan hemen önce çağrılır.
    public func trashRejectionReason(for url: URL, fileManager: FileManager = .default) -> String? {
        if let reason = protectionReason(for: url) { return reason }
        if isUnderAppRoot(PathUtil.key(PathUtil.canonical(url))) {
            return "uygulama klasöründe: yalnız uygulama öğesi olarak taşınır"
        }
        guard isInsideHome(url) else { return "ana klasör dışı" }
        let path = url.standardizedFileURL.path
        var isDir: ObjCBool = false
        // lstat anlamında var mı: bağlantı kırık olsa bile bağlantının kendisi taşınabilir.
        let attrs = try? fileManager.attributesOfItem(atPath: path)
        if attrs == nil { return "yol yok" }
        if fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
           (attrs?[.type] as? FileAttributeType) == .typeDirectory
        {
            var gitIsDir: ObjCBool = false
            if fileManager.fileExists(atPath: path + "/.git", isDirectory: &gitIsDir) {
                return "git deposu kökü (.git içeriyor)"
            }
        }
        return nil
    }

    // MARK: - Uygulama istisnası

    /// `.app` paketi Çöp Kutusu'na taşınamıyorsa nedenini döner. Yalnız `apps` öğeleri için; şunları denetler:
    /// yazıldığı haliyle ve çözülmüş haliyle bir uygulama kökünün DOĞRUDAN çocuğu, adı `<Ad>.app`, kendisi
    /// sembolik bağlantı değil gerçek klasör, kök sembolik bağlantı değil, kullanıcı paketi ve kökü yazabiliyor.
    /// Bundle id (Apple), çalışan uygulama ve Cleaner'ın kendisi `Trasher`'da denetlenir.
    public func appBundleRejectionReason(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        let name = (path as NSString).lastPathComponent
        guard name.count > 4, !name.hasPrefix("."), name.lowercased().hasSuffix(".app") else {
            return "uygulama paketi değil (.app değil)"
        }
        let parent = (path as NSString).deletingLastPathComponent
        // Yazıldığı haliyle doğrudan çocuk (iç içe yol, alt klasör, `..` ile kaçış yok).
        guard let index = appRootLiteralKeys.firstIndex(of: PathUtil.key(parent)) else {
            return "uygulama klasörünün doğrudan çocuğu değil"
        }
        let rootPath = appRoots[index].standardizedFileURL.path
        // Kökün kendisi sembolik bağlantı olamaz (ör. /Applications -> ~/Documents).
        var rst = stat()
        guard lstat(rootPath, &rst) == 0, (rst.st_mode & S_IFMT) == S_IFDIR else {
            return "uygulama klasörü gerçek bir klasör değil (sembolik bağlantı?)"
        }
        // Çözülmüş haliyle de aynı kök (üst klasörlerdeki bağlantılar başka yere götürmüyor).
        guard let realParent = PathUtil.realPath(parent), PathUtil.key(realParent) == appRootKeys[index] else {
            return "uygulama klasörü çözülünce başka yere gidiyor"
        }
        // Ana klasör içindeki tek uygulama kökü ~/Applications'tır; başka bir yere çözülen kök kabul edilmez.
        if PathUtil.isSameOrDescendant(appRootKeys[index], of: homeKey),
           appRootKeys[index] != PathUtil.key(homeKey + "/applications")
        {
            return "uygulama klasörü ana klasörün başka bir yerine çözülüyor"
        }
        var st = stat()
        guard lstat(path, &st) == 0 else { return "yol yok" }
        if (st.st_mode & S_IFMT) == S_IFLNK { return "sembolik bağlantı (paket değil)" }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return "uygulama paketi değil (klasör değil)" }
        return PathPolicy.writeProblem(bundle: path, parent: realParent, stat: st)
    }

    /// Paketi taşımak için paketin kendisine ve üst klasöre yazma izni gerekir (klasör taşınırken `..`
    /// güncellenir). Yoksa nedeni döner.
    static func writeProblem(bundle: String, parent: String, stat st: stat) -> String? {
        if access(parent, W_OK) != 0 { return "yazma izni yok: uygulama klasörüne yazılamıyor (yönetici izni gerekir)" }
        if access(bundle, W_OK) != 0 {
            let err = errno
            // EPERM: izin bitleri değil macOS koruması (Uygulama Yönetimi / TCC, değiştirilemez bayrak).
            if err == EPERM {
                let root = st.st_uid == 0 ? ", sahibi root" : ""
                return "macOS koruması (Uygulama Yönetimi izni gerekir\(root)); Finder ile taşıyın"
            }
            let owner = st.st_uid == 0 ? "sahibi root" : (st.st_uid == getuid() ? "paket salt okunur" : "sahibi başka kullanıcı")
            return "yazma izni yok: \(owner), yönetici izni gerekir (Finder ya da uygulamanın kaldırıcısı ile)"
        }
        return nil
    }

    /// Yolun yazılabilirlik sorunu (tarayıcı kilit nedeni için). Sorun yoksa nil.
    public func appBundleWriteProblem(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        var st = stat()
        guard lstat(path, &st) == 0 else { return "yol yok" }
        return PathPolicy.writeProblem(bundle: path, parent: (path as NSString).deletingLastPathComponent, stat: st)
    }

    /// Uygulama artığı Çöp Kutusu'na taşınamıyorsa nedenini döner. Artık, izinli `~/Library` klasörlerinden
    /// birinin (çözülmüş haliyle) doğrudan çocuğu olmalı ve adı bundle id'den tam türemeli. Var olmayan yol
    /// burada reddedilmez (`trashRejectionReason` ve taşıma anı yakalar).
    public func leftoverRejectionReason(for url: URL, bundleID: String) -> String? {
        guard AppBundleInfo.isValidBundleID(bundleID) else { return "geçersiz bundle id" }
        if AppBundleInfo.isAppleBundleID(bundleID) { return "Apple sistem uygulaması" }
        let path = url.standardizedFileURL.path
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        guard let realParent = PathUtil.realPath(parent) else { return "artık klasörü yok" }
        let parentKey = PathUtil.key(realParent)
        var matched = false
        if parentKey == PathUtil.key(homeKey + "/" + PathPolicy.groupContainersParent) {
            matched = PathPolicy.groupContainerMatches(name, bundleID: bundleID)
        } else if let entry = PathPolicy.leftoverParents.first(where: { PathUtil.key(homeKey + "/" + $0.0) == parentKey }) {
            matched = entry.1(bundleID).contains { $0.lowercased() == name.lowercased() }
        } else {
            return "artık izinli bir ~/Library klasöründe değil"
        }
        guard matched else { return "artık adı bundle id ile tam eşleşmiyor" }
        if let reason = protectionReason(for: url) { return reason }
        guard isInsideHome(url) else { return "ana klasör dışı" }
        return nil
    }
}
