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
    ]

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
    /// Ana klasörde `.<ad>` ve `.<ad>-*`; diğer klasörlerde normalize ad tam eşit.
    public static func matches(entry: String, parent: String, key: String) -> Bool {
        guard !key.isEmpty, let base = baseName(entry, parent: parent), !base.isEmpty else { return false }
        if normalize(base) == key { return true }
        guard parent == "" else { return false }
        var idx = base.startIndex
        while let dash = base[idx...].firstIndex(of: "-") {
            if normalize(String(base[..<dash])) == key { return true }
            idx = base.index(after: dash)
        }
        return false
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

    /// Paketin tam çözülmüş yol anahtarı (bağlantıyla gösterilen paket, gerçeğiyle aynı uygulama sayılır).
    static func bundleKey(_ url: URL) -> String {
        PathUtil.realPath(url.standardizedFileURL.path).map(PathUtil.key) ?? PathUtil.key(PathUtil.canonical(url))
    }

    init(roots: [URL], reader: SafeReader) {
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

    /// Girdi, `excluding` dışındaki kurulu bir uygulamanın adı ya da bundle id'siyle de eşleşiyorsa o uygulama.
    /// `ownerKey` (sahip uygulamanın eşleşen adı) girdiyle TAM eşleşiyorsa, başka uygulamanın yalnız önek
    /// (`.<ad>-*`) eşleşmesi çakışma sayılmaz (ör. `.antigravity-ide` → "Antigravity IDE"nin, "Antigravity"nin değil).
    /// Sahip yalnız önekle eşleşiyorsa başka uygulamanın her türlü eşleşmesi çakışmadır.
    func conflict(entry: String, parent: String, excludingBundleKey: String?, ownerKey: String) -> Entry? {
        let ownerExact = LeftoverNames.matchesExactly(entry: entry, parent: parent, key: ownerKey)
        return entries.first { e in
            guard e.bundleKey != excludingBundleKey else { return false }
            if LeftoverNames.matchesBundleID(entry: entry, parent: parent, bundleID: e.bundleID) { return true }
            return e.nameKeys.contains { k in
                ownerExact ? LeftoverNames.matchesExactly(entry: entry, parent: parent, key: k)
                    : LeftoverNames.matches(entry: entry, parent: parent, key: k)
            }
        }
    }

    /// `excluding` dışında aynı bundle id'li kurulu uygulama var mı?
    func hasOther(bundleID: String, excludingBundleKey: String?) -> Bool {
        entries.contains { $0.bundleKey != excludingBundleKey && $0.bundleID == bundleID.lowercased() }
    }
}
