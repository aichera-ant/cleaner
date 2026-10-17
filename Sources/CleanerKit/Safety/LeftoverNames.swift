import Darwin
import Foundation

/// Ad tabanlı uygulama artığı kuralları (istek, 2026-10-17).
///
/// Uygulamanın adından türeyen normalize ad (küçük harf; boşluk, tire, nokta, alt çizgi yok; en az 4 karakter;
/// genel kelime değil) YALNIZ şu klasörlerin DOĞRUDAN çocuğunda aranır: `~/Library/Application Support`,
/// `Caches`, `Preferences` (`<ad>.plist`), `Logs`, `Saved Application State`, `HTTPStorages`, `WebKit` ve ana
/// klasördeki gizli girdiler (`~/.<ad>`, `~/.<ad>-*`). Containers, Group Containers, iCloud ve başka hiçbir yer
/// ad ile eşleşmez. İçerik okunmaz; yalnız ad.
public enum LeftoverNames {
    /// Ad tabanlı aramanın yapıldığı klasörler (ana klasöre göreli). "" ana klasörün kendisidir (yalnız gizli girdi).
    public static let parents = [
        "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Logs",
        "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit", "",
    ]

    /// Tek başına çok genel adlar: bunlarla eşleşen yol başka araçlara ya da birden çok uygulamaya ait olabilir.
    static let generic: Set<String> = [
        "app", "apps", "application", "applications", "helper", "helpers", "update", "updater", "updates",
        "autoupdate", "install", "installer", "uninstaller", "setup", "launcher", "agent", "daemon", "service",
        "services", "code", "google", "microsoft", "apple", "adobe", "mozilla", "electron", "chrome", "chromium",
        "browser", "mail", "music", "photos", "notes", "calendar", "contacts", "messages", "data", "cache", "caches",
        "config", "configs", "settings", "preferences", "prefs", "support", "logs", "user", "users", "default",
        "local", "library", "temp", "shared", "common", "system", "tools", "utility", "utilities", "studio",
        "editor", "client", "server", "desktop", "cloud", "sync", "drive", "office", "docs", "files", "home",
        "share", "webkit", "http", "httpstorages", "java", "node", "python", "ruby", "swift", "xcode", "docker",
        "terminal", "shell", "trash", "keychain", "keychains", "documents", "downloads", "pictures",
        "movies", "public", "containers", "group", "preview", "safari", "finder", "store", "appstore", "manager",
        "monitor", "viewer", "player", "reader", "plugin", "plugins", "extension", "extensions", "framework",
        "frameworks", "runtime", "bundle", "test", "tests", "demo", "beta", "debug", "release", "main", "core",
        "base", "info", "help", "account", "accounts", "login", "auth", "security", "crash", "crashpad",
        "crashreporter", "logger", "team", "teams",
        // Çalıştırılabilir/paket adı olarak sık geçen genel adlar (ör. Warp'ın çalıştırılabiliri "stable").
        "stable", "applet", "droplet", "run", "start", "starter", "runner", "wrapper", "host", "bootstrap",
        "loader", "nightly", "canary", "insiders", "stub", "binary", "exec", "executable",
    ]

    /// Ana klasörde ASLA ad artığı olmayan gizli girdiler (küçük harf, baştaki nokta dahil): CLI ve geliştirici
    /// araçlarının ayar klasörleri, kimlik bilgileri, kabuk ayarları. Uygulama adı ne olursa olsun aday olmaz.
    static let homeDenied: Set<String> = [
        ".claude", ".codex", ".gemini", ".cursor", ".opencode", ".config", ".local", ".cache", ".kube", ".aws",
        ".azure", ".gcloud", ".docker", ".npm", ".pnpm-store", ".yarn", ".bun", ".cargo", ".rustup", ".gradle",
        ".m2", ".android", ".vscode", ".ssh", ".gnupg", ".profile", ".netrc", ".oh-my-zsh", ".nvm", ".fnm",
        ".pyenv", ".rbenv", ".cloudflared", ".wrangler", ".supabase", ".vercel", ".expo", ".cocoapods", ".swiftpm",
        ".copilot", ".agents",
    ]

    /// Ana klasörde bu öneklerle başlayan gizli girdiler de asla ad artığı değildir (küçük harf).
    static let homeDeniedPrefixes = [".git", ".zsh", ".bash", ".env", ".terraform"]

    /// Ana klasörde adında bunlardan biri geçen gizli girdi ad artığı olmaz (kimlik bilgisi olabilir).
    static let sensitiveWords = ["token", "secret", "key", "credential", "password", "auth", "env"]

    /// Girdi (doğrudan çocuk adı) bu klasörde ad artığı olarak hiç kabul edilmiyorsa nedeni. Yalnız ad; büyük/küçük
    /// harf duyarsız. Kurallar ana klasördeki gizli girdiler içindir (`~/Library` altındaki uygulama klasörleri
    /// etkilenmez).
    public static func deniedReason(entry: String, parent: String) -> String? {
        let lower = entry.lowercased()
        if parent.isEmpty {
            if sensitiveWords.contains(where: { lower.contains($0) }) {
                return "adı kimlik bilgisi/ayar dosyası gibi görünüyor"
            }
            if homeDenied.contains(lower) || homeDeniedPrefixes.contains(where: { lower.hasPrefix($0) })
                || homeDenied.contains(where: { lower.hasPrefix($0 + "-") || lower.hasPrefix($0 + ".") }) {
                return "komut satırı aracı ya da kişisel ayar klasörü (ad artığı olmaz)"
            }
        }
        return nil
    }

    /// Ana klasördeki `~/.<x>` bağımsız bir komut satırı aracının kurulum klasörü mü (ör. `~/.deno`)? (Karar,
    /// 2026-10-17: böyle klasör, aynı adlı uygulama kurulu olsa bile, hiçbir zaman ad artığı adayı olmaz.)
    ///
    /// Koşul: `bin/` alt klasörü (doğrudan ya da aynı klasörün içine giden bağlantı, ör. `versions/current/bin`;
    /// dışarıya giden bağlantı sayılmaz) en az bir bağımsız çalıştırılabilir içeriyor: çalıştırma
    /// biti olan sıradan dosya ya da çözülünce böyle bir dosyaya giden ve hedefi bir uygulama paketinin (`*.app`)
    /// içinde olmayan bağlantı. Hedefi uygulama paketine giden bağlantılar uygulamanın kendi CLI'ıdır (bağımsız
    /// değil; `InstalledApps.commandMatches` iç komut kuralı: kırmızı + not). Yalnız ad listesi, `lstat`, `stat` ve
    /// `realpath`; içerik okunmaz.
    public static let standaloneCLIReason = "bağımsız komut satırı aracı klasörü (içinde bin/ var; ad artığı olmaz)"

    public static func isStandaloneCLIFolder(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
              let bin = binDirectory(of: url),
              let names = try? FileManager.default.contentsOfDirectory(atPath: bin.path)
        else { return false }
        func executableFile(_ s: stat) -> Bool {
            (s.st_mode & S_IFMT) == S_IFREG && (s.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0
        }
        for n in names.prefix(10_000) where !n.hasPrefix(".") {
            let p = bin.appending(path: n).path
            var est = stat()
            guard lstat(p, &est) == 0 else { continue }
            if executableFile(est) { return true }
            guard (est.st_mode & S_IFMT) == S_IFLNK, let target = PathUtil.realPath(p) else { continue }
            var tst = stat()
            guard stat(target, &tst) == 0, executableFile(tst) else { continue }
            let insideApp = target.split(separator: "/").contains { $0.lowercased().hasSuffix(".app") }
            if !insideApp { return true }
        }
        return false
    }

    /// `~/.<x>/bin` klasörü: doğrudan klasörse kendisi; bağlantıysa yalnız çözülen hedef aynı `~/.<x>` klasörünün
    /// İÇİNDE bir klasörse o hedef (ör. `bin -> versions/current/bin`). Dışarıya giden bağlantı sayılmaz (nil).
    static func binDirectory(of url: URL) -> URL? {
        let bin = url.appending(path: "bin")
        var st = stat()
        guard lstat(bin.path, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            return bin
        case S_IFLNK:
            guard let target = PathUtil.realPath(bin.path), let root = PathUtil.realPath(url.path) else { return nil }
            let (t, r) = (PathUtil.key(target), PathUtil.key(root))
            guard t != r, PathUtil.isSameOrDescendant(t, of: r) else { return nil }
            var tst = stat()
            guard stat(target, &tst) == 0, (tst.st_mode & S_IFMT) == S_IFDIR else { return nil }
            return URL(fileURLWithPath: target, isDirectory: true)
        default:
            return nil
        }
    }

    /// Ad artığı klasörün kendisi ya da doğrudan çocuğu `.git` içeriyor mu? Yalnız `lstat` ile varlık; içerik okunmaz.
    public static func containsGitRepository(_ url: URL) -> Bool {
        func has(_ dir: URL) -> Bool {
            var st = stat()
            return lstat(dir.appending(path: ".git").path, &st) == 0
        }
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        if has(url) { return true }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        for n in names.prefix(10_000) {
            let child = url.appending(path: n)
            var cst = stat()
            guard lstat(child.path, &cst) == 0, (cst.st_mode & S_IFMT) == S_IFDIR else { continue }
            if has(child) { return true }
        }
        return false
    }

    /// Küçük harf; boşluk, tire, nokta ve alt çizgi atılır.
    public static func normalize(_ s: String) -> String {
        String(s.lowercased().filter { !($0.isWhitespace || $0 == "-" || $0 == "." || $0 == "_") })
    }

    /// Ad tabanlı aramada kullanılabilir mi? En az 4 karakter, yalnız harf/rakam, genel kelime değil.
    public static func isUsableKey(_ key: String) -> Bool {
        key.count >= 4 && key.count <= 128 && key.allSatisfy { $0.isLetter || $0.isNumber } && !generic.contains(key)
    }

    /// Girdinin bu klasördeki "temel adı" (gizli nokta ve bilinen uzantı atılmış). Bu klasörde ad tabanlı
    /// eşleşmeye uygun değilse nil.
    static func baseName(_ entry: String, parent: String) -> String? {
        guard !entry.isEmpty, !entry.contains("/"), entry != ".", entry != ".." else { return nil }
        let lower = entry.lowercased()
        switch parent {
        case "":
            guard entry.hasPrefix("."), entry.count > 1 else { return nil }
            return String(entry.dropFirst())
        case "Library/Preferences":
            guard lower.hasSuffix(".plist"), entry.count > 6 else { return nil }
            return String(entry.dropLast(6))
        case "Library/Saved Application State":
            return lower.hasSuffix(".savedstate") ? String(entry.dropLast(11)) : entry
        case "Library/HTTPStorages":
            return lower.hasSuffix(".binarycookies") ? String(entry.dropLast(14)) : entry
        default:
            return entry
        }
    }

    /// Girdi (doğrudan çocuk adı) bu klasörde `key` ile ad olarak eşleşiyor mu?
    /// Ana klasörde `.<ad>` ve (yalnız klasörse) `.<ad>-*`; diğer klasörlerde normalize ad tam eşit.
    /// `isDirectory`: girdinin klasör olup olmadığı. Çakışma denetimi (geniş = güvenli) `true` verir.
    public static func matches(entry: String, parent: String, key: String, isDirectory: Bool) -> Bool {
        guard !key.isEmpty else { return false }
        return entryKeys(entry, parent: parent, prefixes: isDirectory).contains(key)
    }

    /// Girdinin eşleşebileceği bütün normalize adlar: temel adın kendisi; ana klasörde `prefixes` ise her `-`
    /// öneki de (`.a-b-c` → `abc`, `a`, `ab`).
    static func entryKeys(_ entry: String, parent: String, prefixes: Bool) -> Set<String> {
        guard let base = baseName(entry, parent: parent), !base.isEmpty else { return [] }
        var out: Set<String> = [normalize(base)]
        guard parent == "", prefixes else { return out }
        var idx = base.startIndex
        while let dash = base[idx...].firstIndex(of: "-") {
            out.insert(normalize(String(base[..<dash])))
            idx = base.index(after: dash)
        }
        out.remove("")
        return out
    }

    /// Tam ad eşleşmesi mi (`.<ad>-*` öneki değil)?
    public static func matchesExactly(entry: String, parent: String, key: String) -> Bool {
        guard !key.isEmpty, let base = baseName(entry, parent: parent), !base.isEmpty else { return false }
        return normalize(base) == key
    }

    /// Girdi bir bundle id'ye ait görünüyor mu? (temel ad bundle id'nin kendisi ya da `<id>.` ile başlıyor,
    /// ya da normalize halleri eşit). Çakışma denetimi için.
    static func matchesBundleID(entry: String, parent: String, bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        guard !id.isEmpty, let base = baseName(entry, parent: parent)?.lowercased() else { return false }
        return base == id || base.hasPrefix(id + ".") || normalize(base) == normalize(id)
    }
}

/// Kurulu uygulamalar (çakışma denetimi için): uygulama köklerinin ve bir alt klasörünün `.app` paketleri,
/// Apple uygulamaları dahil. Yalnız Info.plist (`SafeReader`) okunur.
struct InstalledApps: Sendable {
    struct Entry: Sendable {
        var bundleKey: String
        var bundleID: String
        var nameKeys: Set<String>
    }

    var entries: [Entry]
    /// Komut satırı klasörlerindeki çalıştırılabilirler: normalize ad → bulundukları yerler. Ana klasörde bu adla
    /// eşleşen gizli girdi bir CLI aracının ayarıdır; hiçbir uygulamanın ad artığı olmaz (komut adayın kendi
    /// içinde değilse, bkz. `commandMatches`).
    var commands: [String: [CommandLocation]] = [:]

    /// Normalize komut adları.
    var commandNames: Set<String> { Set(commands.keys) }

    /// Bir komutun yeri. Yalnız yol çözümü (`realpath`); içerik okunmaz.
    struct CommandLocation: Sendable, Equatable {
        /// Klasördeki adı (gösterim için).
        var name: String
        /// Girdinin kendisi: çözülmüş klasör + ad (girdi bağlantıysa bağlantının yeri), `PathUtil.key` biçiminde.
        var entryKey: String
        /// Girdinin tamamen çözülmüş yolu (bağlantıysa hedefi; sıradan dosyada kendisi). Kırık bağlantıda nil.
        var targetKey: String?
    }

    /// Paketin tam çözülmüş yol anahtarı (bağlantıyla gösterilen paket, gerçeğiyle aynı uygulama sayılır).
    static func bundleKey(_ url: URL) -> String {
        PathUtil.realPath(url.standardizedFileURL.path).map(PathUtil.key) ?? PathUtil.key(PathUtil.canonical(url))
    }

    init(roots: [URL], reader: SafeReader, commandDirectories: [URL] = []) {
        commands = InstalledApps.commandCatalog(in: commandDirectories)
        let fm = FileManager.default
        var out: [Entry] = []
        var seen = Set<String>()
        func add(_ bundle: URL) {
            let key = InstalledApps.bundleKey(bundle)
            guard seen.insert(key).inserted, let info = AppBundleInfo.read(bundle, reader: reader) else { return }
            out.append(Entry(bundleKey: key, bundleID: info.bundleID.lowercased(), nameKeys: info.allNameKeys))
        }
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let u = root.appending(path: name)
                if name.lowercased().hasSuffix(".app") { add(u); continue }
                var st = stat()
                guard lstat(u.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
                      let sub = try? fm.contentsOfDirectory(atPath: u.path) else { continue }
                for n in sub.sorted() where !n.hasPrefix(".") && n.lowercased().hasSuffix(".app") {
                    add(u.appending(path: n))
                }
            }
        }
        entries = out
    }

    /// Taranan komut satırı klasörü ve klasör başına girdi sınırı.
    static let maxCommandDirectories = 512
    static let maxCommandsPerDirectory = 20_000

    /// Klasörlerdeki çalıştırılabilir adlar (normalize).
    static func commandNames(in dirs: [URL]) -> Set<String> { Set(commandCatalog(in: dirs).keys) }

    /// Klasörlerdeki çalıştırılabilirler (normalize ad → yerler): sembolik bağlantı ya da çalıştırma biti olan
    /// sıradan dosya. Yalnız ad listesi, `lstat` ve `realpath`; dosya içeriği okunmaz.
    static func commandCatalog(in dirs: [URL]) -> [String: [CommandLocation]] {
        let fm = FileManager.default
        var out: [String: [CommandLocation]] = [:]
        var seen = Set<String>()
        var seenEntries = Set<String>()
        for dir in dirs.prefix(maxCommandDirectories) where seen.insert(PathUtil.key(dir.standardizedFileURL.path)).inserted {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            let realDir = PathUtil.realPath(dir.path) ?? PathUtil.canonicalDirectory(dir)
            for n in names.prefix(maxCommandsPerDirectory) where !n.hasPrefix(".") {
                let p = dir.appending(path: n).path
                var st = stat()
                guard lstat(p, &st) == 0 else { continue }
                let kind = st.st_mode & S_IFMT
                guard kind == S_IFLNK || (kind == S_IFREG && (st.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0)
                else { continue }
                let k = LeftoverNames.normalize(n)
                guard !k.isEmpty else { continue }
                let entryKey = PathUtil.key(realDir == "/" ? "/" + n : realDir + "/" + n)
                guard seenEntries.insert(entryKey).inserted else { continue }
                out[k, default: []].append(CommandLocation(name: n, entryKey: entryKey,
                                                           targetKey: PathUtil.realPath(p).map(PathUtil.key)))
            }
        }
        return out
    }

    /// Ana klasördeki gizli girdinin adıyla (ya da `-` önekiyle) eşleşen komutlar, ikiye ayrılmış:
    /// - `internal`: o adın BÜTÜN yerleri adayın içinde: hedefi adayın içinde (dışarıdan içeriye bağlantı dahil), ya
    ///   da girdinin kendisi adayın içinde ve hedefi sahip uygulamanın paketinde ya da kırık (uygulama önce Çöp
    ///   Kutusu'na taşındıysa). Bunlar çakışma değildir; aday silinince komut da çalışmaz (kırmızı + not).
    /// - `conflicting`: en az bir yeri adayın dışında olan (ya da aday çözülemiyorsa hepsi) komutlar.
    /// Yalnız ana klasör (`parent == ""`) için; diğer klasörlerde ikisi de boş.
    func commandMatches(entry: String, parent: String, candidate: URL?, ownerBundleKey: String?)
        -> (conflicting: [String], internal: [String]) {
        guard parent.isEmpty else { return ([], []) }
        let keys = LeftoverNames.entryKeys(entry, parent: parent, prefixes: true).intersection(commands.keys).sorted()
        guard !keys.isEmpty else { return ([], []) }
        let candKey = candidate.flatMap { PathUtil.realPath($0.standardizedFileURL.path) }.map(PathUtil.key)
        var conflicting: [String] = [], internalNames: [String] = []
        for k in keys {
            let locs = commands[k] ?? []
            let inside = !locs.isEmpty && candKey.map { c in
                locs.allSatisfy { l in
                    if let t = l.targetKey, PathUtil.isSameOrDescendant(t, of: c), t != c { return true }
                    guard l.entryKey != c, PathUtil.isSameOrDescendant(l.entryKey, of: c) else { return false }
                    guard let t = l.targetKey else { return true }
                    return ownerBundleKey.map { PathUtil.isSameOrDescendant(t, of: $0) } ?? false
                }
            } ?? false
            if inside { internalNames.append(locs.first?.name ?? k) } else { conflicting.append(k) }
        }
        return (conflicting, internalNames)
    }

    /// Girdi başka bir sahiple de eşleşiyorsa o sahibin tanımı (bundle id ya da "komut satırı aracı `x`").
    /// - `excluding` dışındaki kurulu bir uygulamanın adı ya da bundle id'si. `ownerKey` (sahip uygulamanın eşleşen
    ///   adı) girdiyle TAM eşleşiyorsa, başka uygulamanın yalnız önek (`.<ad>-*`) eşleşmesi çakışma sayılmaz (ör.
    ///   `.antigravity-ide` → "Antigravity IDE"nin, "Antigravity"nin değil). Sahip yalnız önekle eşleşiyorsa başka
    ///   uygulamanın her türlü eşleşmesi çakışmadır.
    /// - Ana klasörde: adı ya da herhangi bir `-` öneki bir komut satırı çalıştırılabiliriyle aynı olan girdi
    ///   (ör. `~/.claude` ↔ `claude`) çakışmadır.
    ///   Komutun bütün yerleri adayın kendi içindeyse (`commandMatches`) çakışma sayılmaz.
    func conflict(entry: String, parent: String, candidate: URL? = nil, excludingBundleKey: String?,
                  ownerKey: String) -> String? {
        if let cmd = commandMatches(entry: entry, parent: parent, candidate: candidate,
                                    ownerBundleKey: excludingBundleKey).conflicting.first {
            return "komut satırı aracı `\(cmd)`"
        }
        let ownerExact = LeftoverNames.matchesExactly(entry: entry, parent: parent, key: ownerKey)
        return entries.first { e in
            guard e.bundleKey != excludingBundleKey else { return false }
            if LeftoverNames.matchesBundleID(entry: entry, parent: parent, bundleID: e.bundleID) { return true }
            return e.nameKeys.contains { k in
                ownerExact ? LeftoverNames.matchesExactly(entry: entry, parent: parent, key: k)
                    : LeftoverNames.matches(entry: entry, parent: parent, key: k, isDirectory: true)
            }
        }?.bundleID
    }

    /// `excluding` dışında aynı bundle id'li kurulu uygulama var mı?
    func hasOther(bundleID: String, excludingBundleKey: String?) -> Bool {
        entries.contains { $0.bundleKey != excludingBundleKey && $0.bundleID == bundleID.lowercased() }
    }
}
