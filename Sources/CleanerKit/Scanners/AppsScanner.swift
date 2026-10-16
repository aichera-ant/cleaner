import Darwin
import Foundation

/// `/Applications` ve `~/Applications`'taki (`context.pathPolicy.appRoots`) uygulamalar.
///
/// - Yalnız uygulama kökünün doğrudan çocuğu olan gerçek `.app` paketleri (alt klasör, bağlantı yok).
/// - Apple (`com.apple.*`) uygulamaları listelenmez.
/// - Artıklar: yalnız bundle id ile TAM eşleşen `~/Library` yolları (`PathPolicy.leftoverParents`, grup
///   kapsayıcısında `group.<id>` / `<TAKIM>.<id>`). Adla tahmin edilenler alınmaz, yalnız notta "alınmadı" diye
///   gösterilir. Öğenin boyutu paket + artıklardır; artıklar `relatedPaths` ile paketle birlikte taşınır.
/// - Risk: çalışan, Cleaner'ın kendisi, komut satırından kullanılan, son `staleDays` günde artığı değişen ve
///   yazma izni olmayan (sahibi root) paket kilitli; son `staleDays` günde açılan bilgi; geri kalanı (hiç açılmamış
///   ya da uzun süredir açılmamış) sarı "Yeniden indirilir", seçili değil.
public struct AppsScanner: Cleaner {
    public let id = "apps"
    public var categories: Set<Category> { [.apps] }

    /// Bu kadar günden kısa sürede açılmış/kullanılmış uygulama önerilmez.
    public var staleDays: Int
    /// Komut satırı bağlantılarının aranacağı klasörler. nil: PATH'teki yaygın klasörler.
    public var binDirectories: [URL]?

    public init(staleDays: Int = 90, binDirectories: [URL]? = nil) {
        self.staleDays = staleDays
        self.binDirectories = binDirectories
    }

    /// Yaygın klasörler + PATH'teki klasörler (sistem klasörleri hariç).
    static func defaultBinDirectories(home: URL) -> [URL] {
        let fixed = ["/usr/local/bin", "/opt/homebrew/bin"].map { URL(fileURLWithPath: $0) }
            + [home.appending(path: ".local/bin"), home.appending(path: "bin")]
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let system = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/system/", "/var/run/", "/library/apple/"]
        let extra = path.filter { p in
            p.hasPrefix("/") && !system.contains { s in s.hasSuffix("/") ? p.lowercased().hasPrefix(s) : p.lowercased() == s }
        }.map { URL(fileURLWithPath: $0) }
        var seen = Set<String>()
        return (fixed + extra).filter { seen.insert(PathUtil.key($0.standardizedFileURL.path)).inserted }
    }

    /// Kullanım izi olarak bakılan artık klasörleri (Containers ve grup kapsayıcıları sistemce de güncellenebildiği
    /// için sayılmaz).
    static let activityParents: Set<String> = [
        "Library/Application Support", "Library/Caches", "Library/Preferences",
        "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit",
    ]

    public func scan(_ context: ScanContext) async throws -> [CleanItem] {
        let fm = FileManager.default
        let policy = context.pathPolicy
        let reader = context.safeReader
        let processes = context.signals.processes
        let running = RunningApps(processes: processes.runningProcesses(), reader: reader)
        let cliLinks = Self.cliLinks(in: binDirectories ?? Self.defaultBinDirectories(home: context.home))
        var found: [(bundle: URL, info: AppBundleInfo)] = []
        var seen = Set<String>()

        for root in policy.appRoots {
            try context.checkCancellation()
            var st = stat()
            guard lstat(root.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            // Yol kökün yazıldığı haliyle kurulur (öğe yolu ve Spotlight sorgusu tutarlı olsun).
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names.sorted() {
                try context.checkCancellation()
                let bundle = root.appending(path: name, directoryHint: .notDirectory)
                guard name.lowercased().hasSuffix(".app"), !name.hasPrefix(".") else { continue }
                var bst = stat()
                guard lstat(bundle.path, &bst) == 0, (bst.st_mode & S_IFMT) == S_IFDIR else { continue }
                if policy.protectionReason(for: bundle) != nil { continue }
                guard let info = AppBundleInfo.read(bundle, reader: reader), !info.isApple else { continue }
                let key = PathUtil.key(PathUtil.canonical(bundle))
                guard seen.insert(key).inserted else { continue }
                found.append((bundle, info))
            }
        }
        // Aynı bundle id'yi taşıyan birden çok kopya: artıklar ortaktır, hiçbirine eklenmez.
        var byID: [String: [URL]] = [:]
        for f in found { byID[f.info.bundleID.lowercased(), default: []].append(f.bundle) }
        var items: [CleanItem] = []
        for f in found {
            try context.checkCancellation()
            let twins = (byID[f.info.bundleID.lowercased()] ?? []).filter { $0 != f.bundle }
            if let item = try await makeItem(bundle: f.bundle, info: f.info, context: context, running: running,
                                             cliLinks: cliLinks, sharedWith: twins) {
                items.append(item)
            }
        }
        return items
    }

    /// Uygulama köklerinde aynı bundle id'yi taşıyan başka `.app` paketleri (`excluding` hariç).
    static func otherBundles(withID bundleID: String, excluding: URL, appRoots: [URL], reader: SafeReader) -> [URL] {
        let fm = FileManager.default
        let own = PathUtil.key(PathUtil.canonical(excluding))
        var out: [URL] = []
        for root in appRoots {
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names.sorted() where name.lowercased().hasSuffix(".app") && !name.hasPrefix(".") {
                let bundle = root.appending(path: name, directoryHint: .notDirectory)
                guard PathUtil.key(PathUtil.canonical(bundle)) != own else { continue }
                var st = stat()
                guard lstat(bundle.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
                if let id = AppBundleInfo.readBundleID(bundle, reader: reader), id.lowercased() == bundleID.lowercased() {
                    out.append(bundle)
                }
            }
        }
        return out
    }

    func makeItem(bundle: URL, info: AppBundleInfo, context: ScanContext, running: RunningApps,
                  cliLinks: [(link: String, target: String)], sharedWith twins: [URL] = []) async throws -> CleanItem? {
        let policy = context.pathPolicy
        let leftovers = twins.isEmpty ? Self.leftovers(bundleID: info.bundleID, context: context) : []
        let sizes = try await context.sizeMeter.measure([bundle] + leftovers.map(\.url))
        let total = sizes.reduce(UInt64(0)) { $0 &+ $1.allocatedBytes }

        // Son açılış: yalnız Spotlight. Yoksa "bilinmiyor" (paket tarihi kullanım değildir).
        let lastUsed = context.signals.spotlight.lastUsedDate(bundle)
        let date: DateSignal = lastUsed.map { .opened(days: DateSignal.days(from: $0, to: context.now)) } ?? .unknown

        // Kullanım izi: kullanıcı verisi artıklarının en yeni değişikliği.
        var activity: Date?
        for (leftover, m) in zip(leftovers, sizes.dropFirst()) where Self.activityParents.contains(leftover.parent) {
            if let d = m.newestModification, d > (activity ?? .distantPast) { activity = d }
        }
        let activityDays = activity.map { DateSignal.days(from: $0, to: context.now) }

        let bundleKey = PathUtil.key(PathUtil.canonical(bundle))
        let cliUse = cliLinks.first { PathUtil.isSameOrDescendant($0.target, of: bundleKey) }

        var lock: String?
        var risk = Risk.yellow
        if running.isRunning(bundle: bundle, bundleID: info.bundleID) || context.signals.processes.isRunning(info.name) {
            lock = "çalışıyor"
        } else if Self.isSelf(bundle: bundle, bundleID: info.bundleID) {
            lock = "Cleaner'ın kendisi"
        } else if let cliUse {
            lock = "Komut satırından kullanılıyor (\(cliUse.link))"
        } else if let days = date.days, days <= staleDays {
            risk = .info
        } else if lastUsed == nil, let days = activityDays, days <= staleDays {
            lock = "Spotlight kaydı yok ama son \(days) günde kullanılmış (ayar/önbellek değişti)"
        } else if let problem = policy.appBundleWriteProblem(for: bundle) {
            lock = problem
        }

        var notes: [String] = []
        if risk == .yellow && lock == nil { notes.append("Yeniden indirilir") }
        if risk == .info, let days = date.days { notes.append("son \(days) günde açıldı") }
        notes.append(info.bundleID + (info.version.map { " \($0)" } ?? ""))
        if !leftovers.isEmpty {
            let groups = Array(Set(leftovers.map { ($0.parent as NSString).lastPathComponent })).sorted()
            notes.append("artıklar (\(leftovers.count)): \(groups.joined(separator: ", "))")
        }
        if !twins.isEmpty {
            notes.append("aynı bundle id'li başka kopya kurulu (\(twins.map(\.path).joined(separator: ", "))); artıklar ortak olduğu için eklenmedi")
        }
        if info.isAppStore { notes.append("App Store'dan kurulmuş") }
        if !info.uninstallerHints.isEmpty {
            notes.append("kendi kaldırıcısı önerilir (\(info.uninstallerHints.joined(separator: ", ")))")
        }
        let guesses = Self.nameGuesses(info: info, home: context.home)
        if !guesses.isEmpty {
            notes.append("adla eşleşen, alınmadı: " + guesses.joined(separator: ", "))
        }

        return CleanItem(
            category: .apps,
            name: info.name,
            path: bundle.path,
            allocatedBytes: total,
            risk: risk,
            dateSignal: date,
            lockReason: lock,
            note: notes.joined(separator: "; "),
            method: .trash,
            relatedPaths: leftovers.map(\.url.path)
        )
    }

    static func isSelf(bundle: URL, bundleID: String) -> Bool {
        if let own = Bundle.main.bundleIdentifier, own.lowercased() == bundleID.lowercased() { return true }
        if let exe = Bundle.main.executableURL {
            return PathUtil.isSameOrDescendant(PathUtil.key(PathUtil.canonical(exe)), of: PathUtil.key(PathUtil.canonical(bundle)))
        }
        return false
    }

    /// Bundle id ile tam eşleşen artıklar. Her biri `PathPolicy.leftoverRejectionReason` ile denetlenir;
    /// geçmeyen (korunan, bağlantıyla dışarı kaçan ...) alınmaz.
    static func leftovers(bundleID: String, context: ScanContext) -> [(url: URL, parent: String)] {
        let fm = FileManager.default
        let policy = context.pathPolicy
        var result: [(url: URL, parent: String)] = []
        func consider(_ url: URL, parent: String) {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return }
            guard policy.leftoverRejectionReason(for: url, bundleID: bundleID) == nil,
                  policy.trashRejectionReason(for: url) == nil
            else { return }
            result.append((url, parent))
        }
        for (parent, names) in PathPolicy.leftoverParents {
            let dir = context.home.appending(path: parent)
            for n in names(bundleID) { consider(dir.appending(path: n), parent: parent) }
        }
        let groupDir = context.home.appending(path: PathPolicy.groupContainersParent)
        if let names = try? fm.contentsOfDirectory(atPath: groupDir.path) {
            for n in names.sorted() where PathPolicy.groupContainerMatches(n, bundleID: bundleID) {
                consider(groupDir.appending(path: n), parent: PathPolicy.groupContainersParent)
            }
        }
        return result
    }

    /// Uygulamanın adıyla duran ama bundle id ile eşleşmeyen yerler (yalnız ipucu; taşınmaz).
    static func nameGuesses(info: AppBundleInfo, home: URL) -> [String] {
        let name = info.name
        guard !name.isEmpty, !name.contains("/") else { return [] }
        let compact = name.lowercased().replacingOccurrences(of: " ", with: "")
        let candidates = [
            "Library/Application Support/\(name)", "Library/Caches/\(name)",
            ".\(compact)", ".\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
        ]
        var out: [String] = []
        var seen = Set<String>()
        for rel in candidates where seen.insert(rel.lowercased()).inserted {
            var st = stat()
            if lstat(home.appending(path: rel).path, &st) == 0 { out.append("~/" + rel) }
        }
        return out
    }

    /// Komut satırı klasörlerindeki sembolik bağlantılar ve çözülmüş hedefleri (yalnız `.app` içine gidenler).
    static func cliLinks(in dirs: [URL]) -> [(link: String, target: String)] {
        let fm = FileManager.default
        var out: [(link: String, target: String)] = []
        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for n in names.sorted() {
                let p = dir.appending(path: n).path
                var st = stat()
                guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK,
                      let real = PathUtil.realPath(p), real.lowercased().contains(".app/")
                else { continue }
                out.append((n, PathUtil.key(real)))
            }
        }
        return out
    }
}
