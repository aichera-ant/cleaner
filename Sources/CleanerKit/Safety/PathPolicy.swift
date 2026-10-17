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
    /// Çakışma denetiminde (ad tabanlı artık) ayrıca bakılan, taşınmayan uygulama kökleri. Varsayılan
    /// `/System/Applications`; uygulama kökleri dışarıdan verilmişse (test) boş.
    public let conflictOnlyAppRoots: [URL]
    /// Ad tabanlı artık çakışmasında çalıştırılabilir adlarına bakılan komut satırı klasörleri
    /// (`InstalledApps.commandNames`). Varsayılan: PATH + yaygın sistem/Homebrew klasörleri + ana klasördeki
    /// bilinen araç klasörleri (`.local/bin`, npm, bun, cargo, nvm/fnm, `~/.<x>/bin` ...). Uygulama kökleri dışarıdan verilmişse
    /// (test) yalnız ana klasördekiler.
    public let commandDirectories: [URL]
    /// Uygulama köklerinin yazıldığı (standart, çözülmemiş) yollarının anahtarları.
    private let appRootLiteralKeys: [String]
    /// Uygulama köklerinin çözülmüş yollarının anahtarları (`appRootLiteralKeys` ile aynı sırada).
    private let appRootKeys: [String]
    /// Kendisi korunan (içindekiler öğe olabilir) yollar.
    private let exactKeys: Set<String>
    /// Kendisi ve altı tamamen korunan yollar.
    private let subtreeKeys: [String]
    /// Paket yazılabilirliği gözlemi. Gerçekte `access(2)` + `lstat`; testte sahte (root sahipliği ve
    /// Uygulama Yönetimi koruması geçici klasörde kurulamaz).
    var writeProbe: AppWriteProbe = .live

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

    public init(home: URL, appRoots: [URL]? = nil, commandDirectories: [URL]? = nil) {
        self.home = home
        let homeKey = PathUtil.key(PathUtil.canonicalDirectory(home))
        self.homeKey = homeKey
        self.exactKeys = Set(PathPolicy.homeExactRoots.map { PathUtil.key(homeKey + "/" + $0) } + [homeKey])
        self.subtreeKeys = PathPolicy.homeSubtreeRoots.map { PathUtil.key(homeKey + "/" + $0) }
        let roots = appRoots ?? PathPolicy.defaultAppRoots(home: home)
        self.appRoots = roots
        self.conflictOnlyAppRoots = appRoots == nil ? [URL(fileURLWithPath: "/System/Applications", isDirectory: true)] : []
        self.commandDirectories = commandDirectories
            ?? PathPolicy.defaultCommandDirectories(home: home, includeSystem: appRoots == nil)
        self.appRootLiteralKeys = roots.map { PathUtil.key($0.standardizedFileURL.path) }
        self.appRootKeys = roots.map { PathUtil.key(PathUtil.canonicalDirectory($0)) }
    }

    /// Ana klasöre göreli bilinen komut satırı klasörleri.
    static let homeCommandDirectories = [
        ".local/bin", "bin", ".npm-global/bin", ".bun/bin", ".cargo/bin", ".deno/bin", "go/bin", ".volta/bin",
        ".yarn/bin", "Library/pnpm", ".fnm/aliases/default/bin", ".local/share/fnm/aliases/default/bin",
        "Library/Application Support/fnm/aliases/default/bin", ".pyenv/shims", ".rbenv/shims", ".rd/bin",
        ".docker/bin", ".lmstudio/bin", ".opencode/bin", ".claude/local", ".railway/bin",
    ]
    /// Ana klasördeki `~/.<x>/bin` klasörlerinden en çok bu kadarı (yalnız doğrudan `~/.<x>/bin`) eklenir.
    static let maxHomeDotBinDirectories = 64

    /// Ana klasördeki gizli klasörlerin doğrudan `bin` klasörleri (`~/.<x>/bin`), ada göre sıralı, en çok
    /// `maxHomeDotBinDirectories`. Yalnız ad listesi ve `lstat`.
    static func homeDotBinDirectories(home: URL) -> [URL] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? [])
            .filter { $0.hasPrefix(".") && $0 != "." && $0 != ".." }.sorted()
        var out: [URL] = []
        for n in names {
            let bin = home.appending(path: n).appending(path: "bin")
            var st = stat()
            guard lstat(bin.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            out.append(bin)
            if out.count >= maxHomeDotBinDirectories { break }
        }
        return out
    }
    /// Ana klasöre göreli, sürüm başına `bin` içeren klasörler (`<kök>/<sürüm>/<son ek>`).
    static let homeVersionedCommandDirectories = [
        (".nvm/versions/node", "bin"), (".local/share/fnm/node-versions", "installation/bin"),
        ("Library/Application Support/fnm/node-versions", "installation/bin"), (".fnm/node-versions", "installation/bin"),
    ]

    /// Varsayılan komut satırı klasörleri. `includeSystem`: PATH ve sistem/Homebrew klasörleri de.
    public static func defaultCommandDirectories(home: URL, includeSystem: Bool) -> [URL] {
        var out: [URL] = homeCommandDirectories.map { home.appending(path: $0) } + homeDotBinDirectories(home: home)
        let fm = FileManager.default
        for (root, suffix) in homeVersionedCommandDirectories {
            let r = home.appending(path: root)
            for v in ((try? fm.contentsOfDirectory(atPath: r.path)) ?? []).sorted().prefix(64) where !v.hasPrefix(".") {
                out.append(r.appending(path: v).appending(path: suffix))
            }
        }
        if includeSystem {
            out += ["/usr/local/bin", "/usr/local/sbin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/bin", "/bin",
                    "/usr/sbin", "/sbin", "/opt/local/bin"].map { URL(fileURLWithPath: $0) }
            let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
            out += path.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert(PathUtil.key($0.standardizedFileURL.path)).inserted }
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
    ///
    /// `allowingAuthorization`: true ise yalnız yetkiyle aşılabilen yazma sorunu (`AppWriteAccess.needsAuthorization`:
    /// Uygulama Yönetimi koruması, root sahipliği) ret nedeni sayılmaz; diğer bütün koşullar aynen geçerlidir.
    public func appBundleRejectionReason(for url: URL, allowingAuthorization: Bool = false) -> String? {
        switch appBundleCheck(for: url) {
        case .rejected(let reason):
            return reason
        case .valid(let access):
            switch access {
            case .writable: return nil
            case .needsAuthorization(let reason): return allowingAuthorization ? nil : reason
            case .blocked(let reason): return reason
            }
        }
    }

    enum AppBundleCheck: Equatable {
        case rejected(String)
        case valid(AppWriteAccess)
    }

    /// Yapısal kontroller (doğrudan çocuk, bağlantı yok ...) ve geçerse yazma durumu.
    func appBundleCheck(for url: URL) -> AppBundleCheck {
        let path = url.standardizedFileURL.path
        let name = (path as NSString).lastPathComponent
        guard name.count > 4, !name.hasPrefix("."), name.lowercased().hasSuffix(".app") else {
            return .rejected("uygulama paketi değil (.app değil)")
        }
        let parent = (path as NSString).deletingLastPathComponent
        // Yazıldığı haliyle doğrudan çocuk (iç içe yol, alt klasör, `..` ile kaçış yok).
        guard let index = appRootLiteralKeys.firstIndex(of: PathUtil.key(parent)) else {
            return .rejected("uygulama klasörünün doğrudan çocuğu değil")
        }
        let rootPath = appRoots[index].standardizedFileURL.path
        // Kökün kendisi sembolik bağlantı olamaz (ör. /Applications -> ~/Documents).
        var rst = stat()
        guard lstat(rootPath, &rst) == 0, (rst.st_mode & S_IFMT) == S_IFDIR else {
            return .rejected("uygulama klasörü gerçek bir klasör değil (sembolik bağlantı?)")
        }
        // Çözülmüş haliyle de aynı kök (üst klasörlerdeki bağlantılar başka yere götürmüyor).
        guard let realParent = PathUtil.realPath(parent), PathUtil.key(realParent) == appRootKeys[index] else {
            return .rejected("uygulama klasörü çözülünce başka yere gidiyor")
        }
        // Ana klasör içindeki tek uygulama kökü ~/Applications'tır; başka bir yere çözülen kök kabul edilmez.
        if PathUtil.isSameOrDescendant(appRootKeys[index], of: homeKey),
           appRootKeys[index] != PathUtil.key(homeKey + "/applications")
        {
            return .rejected("uygulama klasörü ana klasörün başka bir yerine çözülüyor")
        }
        var st = stat()
        guard lstat(path, &st) == 0 else { return .rejected("yol yok") }
        if (st.st_mode & S_IFMT) == S_IFLNK { return .rejected("sembolik bağlantı (paket değil)") }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return .rejected("uygulama paketi değil (klasör değil)") }
        return .valid(PathPolicy.classify(writeProbe.facts(path, realParent)))
    }

    /// Paketi taşımak için paketin kendisine ve üst klasöre yazma izni gerekir (klasör taşınırken `..`
    /// güncellenir). Yalnız `access(2)` ve `lstat` ile bakılır; hiçbir dosya taşınmaz ya da değiştirilmez.
    ///
    /// - Üst klasöre yazılamıyor: engelli (yetkili taşımaya da açılmaz).
    /// - Pakete yazılamıyor ve `EPERM`: macOS Uygulama Yönetimi koruması (izin bitleri değil) → yetki gerekir.
    /// - Pakete yazılamıyor, `EACCES` ve sahibi root: yetki gerekir (Finder gibi parola/Touch ID).
    /// - Diğer (salt okunur kendi paketi, başka kullanıcının paketi, salt okunur birim ...): engelli.
    static func classify(_ f: AppWriteFacts) -> AppWriteAccess {
        if !f.parentWritable {
            return .blocked("yazma izni yok: uygulama klasörüne yazılamıyor (yönetici izni gerekir)")
        }
        guard let err = f.bundleErrno else { return .writable }
        if err == EPERM {
            let root = f.ownerUID == 0 ? ", sahibi root" : ""
            return .needsAuthorization("macOS Uygulama Yönetimi koruması\(root); macOS parola ya da Touch ID isteyecek")
        }
        if err == EACCES, f.ownerUID == 0 {
            return .needsAuthorization("sahibi root; macOS parola ya da Touch ID isteyecek")
        }
        if err == EACCES {
            let owner = f.ownerUID == f.currentUID ? "paket salt okunur" : "sahibi başka kullanıcı"
            return .blocked("yazma izni yok: \(owner), yönetici izni gerekir (Finder ya da uygulamanın kaldırıcısı ile)")
        }
        return .blocked("yazma izni yok (hata \(err)): \(String(cString: strerror(err)))")
    }

    /// Paketin yazma durumu (tarayıcı kilit/yetki kararı için). Yapısal kontrol yapmaz.
    public func appBundleWriteAccess(for url: URL) -> AppWriteAccess {
        let path = url.standardizedFileURL.path
        var st = stat()
        guard lstat(path, &st) == 0 else { return .blocked("yol yok") }
        let parent = (path as NSString).deletingLastPathComponent
        return PathPolicy.classify(writeProbe.facts(path, PathUtil.realPath(parent) ?? parent))
    }

    /// Yolun yazılabilirlik sorunu (yetki gerektiren dahil). Sorun yoksa nil.
    public func appBundleWriteProblem(for url: URL) -> String? {
        appBundleWriteAccess(for: url).problem
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

    /// Ad tabanlı artık (`LeftoverNames`) Çöp Kutusu'na taşınamıyorsa nedenini döner. Yol, izinli klasörlerden
    /// birinin (yazıldığı ve çözülmüş haliyle) DOĞRUDAN çocuğu olmalı, kendisi sembolik bağlantı olmamalı, adı
    /// `key` ile eşleşmeli (`LeftoverNames.matches`; `.<ad>-*` öneki yalnız klasörde), sabit ret listesinde ya da
    /// adında kimlik bilgisi sözcüğü olmamalı (`LeftoverNames.deniedReason`) ve `key` kullanılabilir (genel değil)
    /// olmalı. Containers,
    /// Group Containers, iCloud ve başka hiçbir yer kabul edilmez. Çakışan kurulu uygulama ve çalışan uygulama
    /// denetimi çağıranda (`AppsScanner`, `Trasher`).
    /// Yolun (yazıldığı haliyle) üst klasörü ad tabanlı arama klasörlerinden biriyse onun göreli adı
    /// (`LeftoverNames.parents`; ana klasör için ""), değilse nil. Yalnız yol metnine bakar.
    public func nameLeftoverParent(for url: URL) -> String? {
        let parent = PathUtil.key((url.standardizedFileURL.path as NSString).deletingLastPathComponent)
        let literalHome = PathUtil.key(home.standardizedFileURL.path)
        return LeftoverNames.parents.first { p in
            let suffix = p.isEmpty ? "" : "/" + p
            return PathUtil.key(literalHome + suffix) == parent || PathUtil.key(homeKey + suffix) == parent
        }
    }

    public func nameLeftoverRejectionReason(for url: URL, key: String) -> String? {
        guard LeftoverNames.isUsableKey(key) else { return "ad çok kısa ya da çok genel" }
        let path = url.standardizedFileURL.path
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        guard let rel = nameLeftoverParent(for: url) else { return "artık ad eşleşmesine izinli bir klasörde değil" }
        guard let realParent = PathUtil.realPath(parent),
              PathUtil.key(realParent) == PathUtil.key(homeKey + (rel.isEmpty ? "" : "/" + rel))
        else { return "artık klasörü çözülünce başka yere gidiyor" }
        var st = stat()
        guard lstat(path, &st) == 0 else { return "yol yok" }
        if (st.st_mode & S_IFMT) == S_IFLNK { return "sembolik bağlantı" }
        // Yalnız klasör ya da sıradan dosya (soket, FIFO, aygıt dosyası değil).
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        guard isDir || (st.st_mode & S_IFMT) == S_IFREG else { return "klasör ya da dosya değil" }
        if let reason = LeftoverNames.deniedReason(entry: name, parent: rel) { return reason }
        if rel.isEmpty, isDir, LeftoverNames.isStandaloneCLIFolder(url) {
            return LeftoverNames.standaloneCLIReason
        }
        // `.<ad>-*` önek eşleşmesi yalnız klasörde; dosyada yalnız tam ad.
        guard LeftoverNames.matches(entry: name, parent: rel, key: key, isDirectory: isDir)
        else { return "artık adı uygulama adıyla eşleşmiyor" }
        if let reason = protectionReason(for: url) { return reason }
        guard isInsideHome(url) else { return "ana klasör dışı" }
        return nil
    }
}

/// Uygulama paketinin yazma durumu.
public enum AppWriteAccess: Sendable, Equatable {
    /// Kullanıcı yetkisiyle taşınabilir.
    case writable
    /// Yalnız yetkiyle (macOS parola/Touch ID, `NSWorkspace.recycle`) taşınabilir: Uygulama Yönetimi koruması
    /// ya da root sahipliği.
    case needsAuthorization(String)
    /// Taşınamaz (yetkili taşımaya da açılmaz).
    case blocked(String)

    /// Sorun metni; yazılabilirse nil.
    public var problem: String? {
        switch self {
        case .writable: nil
        case .needsAuthorization(let r), .blocked(let r): r
        }
    }
}

/// Yazma gözlemi: üst klasör yazılabilir mi, pakete `access(W_OK)` hatası, sahibi.
struct AppWriteFacts: Sendable, Equatable {
    var parentWritable: Bool
    /// nil: pakete yazılabiliyor.
    var bundleErrno: Int32?
    var ownerUID: uid_t
    var currentUID: uid_t = getuid()
}

struct AppWriteProbe: Sendable {
    /// (paket yolu, çözülmüş üst klasör) -> gözlem.
    let facts: @Sendable (String, String) -> AppWriteFacts

    static let live = AppWriteProbe { bundle, parent in
        let parentOK = access(parent, W_OK) == 0
        var bundleErr: Int32?
        if access(bundle, W_OK) != 0 { bundleErr = errno }
        var st = stat()
        let uid: uid_t = lstat(bundle, &st) == 0 ? st.st_uid : uid_t.max
        return AppWriteFacts(parentWritable: parentOK, bundleErrno: bundleErr, ownerUID: uid)
    }
}
