import Foundation

/// Korunan yollar ve taşıma izni. Tek kaynak: hem tarama (öğe olabilir mi) hem Çöp Kutusu (taşınabilir mi)
/// bu tipten geçer.
///
/// Kurallar:
/// - Hiçbir zaman öğe olamaz: ana klasörün kendisi, standart kök klasörler (Belgeler, Masaüstü, İndirilenler,
///   Library, Library/Caches ...), iCloud ve CloudStorage altı, `~/Library/Keychains`, `~/.ssh`, `~/.gnupg`
///   altı, herhangi bir `.git` klasörü ve içi, sistem klasörleri, korunan bir yolu içeren her üst klasör.
/// - Taşınamaz: yukarıdakiler, ana klasör dışındaki her şey, doğrudan `.git` içeren klasör (git deposu kökü).
public struct PathPolicy: Sendable {
    public let home: URL
    private let homeKey: String
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

    public init(home: URL) {
        self.home = home
        let homeKey = PathUtil.key(PathUtil.canonicalDirectory(home))
        self.homeKey = homeKey
        self.exactKeys = Set(PathPolicy.homeExactRoots.map { PathUtil.key(homeKey + "/" + $0) } + [homeKey])
        self.subtreeKeys = PathPolicy.homeSubtreeRoots.map { PathUtil.key(homeKey + "/" + $0) }
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
            for p in PathPolicy.systemPrefixes where PathUtil.isSameOrDescendant(k, of: p) {
                // /Applications altındaki uygulamalar öğe olabilir (yalnız listelenir, taşınamaz).
                if p == "/applications" && k != "/applications" { continue }
                // /Users altında ana klasör dışı: başka kullanıcı.
                return "sistem klasörü"
            }
        }
        return nil
    }

    /// Yol Çöp Kutusu'na taşınamıyorsa nedenini döner. Taşımadan hemen önce çağrılır.
    public func trashRejectionReason(for url: URL, fileManager: FileManager = .default) -> String? {
        if let reason = protectionReason(for: url) { return reason }
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
}
