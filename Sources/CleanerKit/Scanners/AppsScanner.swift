import Darwin
import Foundation

/// `/Applications` ve `~/Applications`'taki (`context.pathPolicy.appRoots`) uygulamalar.
///
/// - Yalnız uygulama kökünün doğrudan çocuğu olan gerçek `.app` paketleri (alt klasör, bağlantı yok).
/// - Apple (`com.apple.*`) uygulamaları listelenmez.
/// - Artıklar AYRI öğedir (`apps` kategorisi, `parentAppID` = uygulama öğesinin id'si); uygulama öğesi
///   `relatedPaths` taşımaz, boyutu yalnız pakettir (`leftoverBytes`: kesin artıkların toplamı, salt bilgi).
///   - Kesin (`.bundleID`): bundle id ile TAM eşleşen `~/Library` yolları (`PathPolicy.leftoverParents`, grup
///     kapsayıcısında `group.<id>` / `<TAKIM>.<id>`). Yeşil, `preselect = false` (arayüz uygulama seçilince işaretler).
///   - Ad tabanlı (`.name`): `LeftoverNames` kuralları (yalnız izinli klasörlerin doğrudan çocuğu, genel ad yok,
///     başka kurulu uygulamanın adı ya da bundle id'siyle ve ana klasörde bir komut satırı çalıştırılabiliriyle
///     çakışan yok, sabit ret listesi ve kimlik bilgisi sözcükleri yok, `.<ad>-*` yalnız klasör, sembolik bağlantı
///     yok). Sarı, `preselect = false`; içinde (ya da doğrudan çocuğunda) `.git` olan klasör ve adıyla eşleşen
///     komutu kendi içinde olan (uygulamanın kendi CLI'ı, `InstalledApps.commandMatches`) girdi kırmızı.
///   - Uygulama kilitliyse (çalışıyor, Cleaner, yapısal ret) artıkları da kilitlidir; uygulama kırmızıysa (komut
///     satırı bağlantısı) kesin artıklar da sarıdır. Aynı bundle id'li başka kopya kuruluysa artık öğesi üretilmez.
/// - Kilit yalnız: çalışan, Hepp Cleaner'ın kendisi ve dar istisnanın yapısal reddi (`.rejected`, `.blocked`: iç içe,
///   bağlantı, başka kullanıcının paketi ...). Kullanım işaretleri kilit değil, uyarıdır (karar kullanıcıda,
///   `preselect = false`): komut satırı bağlantısı kırmızı, son `staleDays` günde açılan ya da Spotlight kaydı
///   olmayıp artığı son `staleDays` günde değişen sarı. Geri kalanı (hiç açılmamış ya da uzun süredir açılmamış)
///   sarı "Yeniden indirilir", seçili değil.
/// - Uygulama Yönetimi koruması (`EPERM`) ya da root sahipliği yüzünden yazılamayan ama dar istisnanın diğer
///   bütün koşullarını sağlayan paket kilitlenmez: `needsAuthorization = true`, `preselect = false`, not
///   "macOS parola ya da Touch ID isteyecek". Yalnız `Trasher`'a yetkili taşıyıcı verilmişse taşınır.
public struct AppsScanner: Cleaner {
    public let id = "apps"
    public var categories: Set<Category> { [.apps] }

    /// Bu kadar günden kısa sürede açılmış/kullanılmış uygulama uyarılı (sarı, seçili değil); kilitli değil.
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
        let installed = InstalledApps(roots: policy.appRoots + policy.conflictOnlyAppRoots, reader: reader,
                                      commandDirectories: policy.commandDirectories + (binDirectories ?? []))
        let listings = Self.nameListings(home: context.home)
        var items: [CleanItem] = []
        for f in found {
            try context.checkCancellation()
            let twins = (byID[f.info.bundleID.lowercased()] ?? []).filter { $0 != f.bundle }
            items += try await makeItems(bundle: f.bundle, info: f.info, context: context, running: running,
                                         cliLinks: cliLinks, sharedWith: twins, installed: installed, listings: listings)
        }
        return items
    }

    /// Ad tabanlı arama klasörlerinin girdileri (bir kez listelenir). Klasörün kendisi bağlantıysa boş.
    static func nameListings(home: URL) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for rel in LeftoverNames.parents {
            let dir = rel.isEmpty ? home : home.appending(path: rel)
            var st = stat()
            guard lstat(dir.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
            else { continue }
            out[rel] = rel.isEmpty ? names.filter { $0.hasPrefix(".") }.sorted() : names.sorted()
        }
        return out
    }

    /// Bir uygulamanın en fazla kaç ad tabanlı artık adayı olabilir.
    static let maxNameLeftovers = 32

    /// Ad tabanlı artık adayları (kesin artıklar hariç). Her biri `PathPolicy.nameLeftoverRejectionReason` ve
    /// `trashRejectionReason`'dan geçer; başka kurulu uygulamayla çakışan alınmaz.
    static func nameLeftovers(info: AppBundleInfo, bundle: URL, exact: [URL], context: ScanContext,
                              installed: InstalledApps, listings: [String: [String]]) -> [NameLeftover] {
        let keys = info.leftoverNameKeys.sorted()
        guard !keys.isEmpty else { return [] }
        let policy = context.pathPolicy
        let bundleKey = InstalledApps.bundleKey(bundle)
        let exactKeys = Set(exact.map { PathUtil.canonicalKey($0.path) })
        var out: [NameLeftover] = []
        for rel in LeftoverNames.parents {
            let dir = rel.isEmpty ? context.home : context.home.appending(path: rel)
            for entry in listings[rel] ?? [] {
                // Tam eşleşen ad önce (önek eşleşmesinden güçlü). Önek (`.<ad>-*`) yalnız klasörde.
                let url = dir.appending(path: entry)
                guard LeftoverNames.deniedReason(entry: entry, parent: rel) == nil else { continue }
                var st = stat()
                guard lstat(url.path, &st) == 0 else { continue }
                let isDir = (st.st_mode & S_IFMT) == S_IFDIR
                guard let key = keys.first(where: { LeftoverNames.matchesExactly(entry: entry, parent: rel, key: $0) })
                    ?? keys.first(where: { LeftoverNames.matches(entry: entry, parent: rel, key: $0, isDirectory: isDir) })
                else { continue }
                guard !exactKeys.contains(PathUtil.canonicalKey(url.path)),
                      policy.nameLeftoverRejectionReason(for: url, key: key) == nil,
                      policy.trashRejectionReason(for: url) == nil,
                      installed.conflict(entry: entry, parent: rel, candidate: url, excludingBundleKey: bundleKey,
                                         ownerKey: key) == nil
                else { continue }
                let inner = installed.commandMatches(entry: entry, parent: rel, candidate: url,
                                                     ownerBundleKey: bundleKey).internal
                out.append(NameLeftover(url: url, parent: rel, key: key,
                                        hasGitRepository: isDir && LeftoverNames.containsGitRepository(url),
                                        internalCommands: inner))
                if out.count >= maxNameLeftovers { return out }
            }
        }
        return out
    }

    /// Ad tabanlı artık adayı.
    struct NameLeftover {
        var url: URL
        var parent: String
        var key: String
        /// Klasörün kendisi ya da doğrudan çocuğu `.git` içeriyor (kişisel ayar/dotfiles olabilir): kırmızı.
        var hasGitRepository: Bool
        /// Adayın kendi içindeki, adıyla eşleşen komutlar (`InstalledApps.commandMatches`): kırmızı.
        var internalCommands: [String] = []
    }

    static let gitRepositoryNote = "İçinde git deposu var; kişisel ayar/dotfiles olabilir"

    /// Adayın içindeki komut(lar) için not.
    static func internalCommandNote(_ names: [String]) -> String {
        "İçindeki \(names.map { "`\($0)`" }.joined(separator: ", ")) \(internalCommandMarker); terminalde artık çalışmaz"
    }

    /// İç komut notunun sabit parçası (taşıma anında notun varlığı buna bakılarak denetlenir).
    static let internalCommandMarker = "komutu da silinir"

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

    func makeItems(bundle: URL, info: AppBundleInfo, context: ScanContext, running: RunningApps,
                   cliLinks: [(link: String, target: String)], sharedWith twins: [URL] = [],
                   installed: InstalledApps, listings: [String: [String]]) async throws -> [CleanItem] {
        let policy = context.pathPolicy
        let leftovers = twins.isEmpty ? Self.leftovers(bundleID: info.bundleID, context: context) : []
        let named = twins.isEmpty
            ? Self.nameLeftovers(info: info, bundle: bundle, exact: leftovers.map(\.url), context: context,
                                 installed: installed, listings: listings)
            : []
        let sizes = try await context.sizeMeter.measure([bundle] + leftovers.map(\.url) + named.map(\.url))
        let exactSizes = Array(sizes.dropFirst().prefix(leftovers.count))
        let namedSizes = Array(sizes.dropFirst(1 + leftovers.count))
        let exactBytes = exactSizes.reduce(UInt64(0)) { $0 &+ $1.allocatedBytes }

        // Son açılış: yalnız Spotlight. Yoksa "bilinmiyor" (paket tarihi kullanım değildir).
        let lastUsed = context.signals.spotlight.lastUsedDate(bundle)
        let date: DateSignal = lastUsed.map { .opened(days: DateSignal.days(from: $0, to: context.now)) } ?? .unknown

        // Kullanım izi: kullanıcı verisi artıklarının en yeni değişikliği.
        var activity: Date?
        for (leftover, m) in zip(leftovers, exactSizes) where Self.activityParents.contains(leftover.parent) {
            if let d = m.newestModification, d > (activity ?? .distantPast) { activity = d }
        }
        let activityDays = activity.map { DateSignal.days(from: $0, to: context.now) }

        let bundleKey = PathUtil.key(PathUtil.canonical(bundle))
        let cliUse = cliLinks.first { PathUtil.isSameOrDescendant($0.target, of: bundleKey) }

        // Kilit yalnız: çalışıyor, Hepp Cleaner'ın kendisi, dar istisnanın yapısal reddi. Kullanım işaretleri (komut
        // satırı bağlantısı, yakın açılış, yakın kullanım izi) kilit değil, uyarıdır: karar kullanıcıda.
        var lock: String?
        var risk = Risk.yellow
        var needsAuthorization = false
        var cautions: [String] = []
        if running.isRunning(bundle: bundle, bundleID: info.bundleID) || context.signals.processes.isRunning(info.name) {
            lock = "çalışıyor"
        } else if Self.isSelf(bundle: bundle, bundleID: info.bundleID) {
            lock = "Hepp Cleaner'ın kendisi"
        } else {
            switch policy.appBundleCheck(for: bundle) {
            case .rejected(let reason): lock = reason
            case .valid(.writable): break
            case .valid(.blocked(let reason)): lock = reason
            case .valid(.needsAuthorization):
                // Uygulama Yönetimi koruması / root sahipliği: kilitli değil, yalnız yetkili taşıyıcıyla
                // (macOS parola/Touch ID) taşınır; varsayılan seçimde değil.
                needsAuthorization = true
            }
        }
        if lock == nil {
            if let cliUse {
                risk = .red
                cautions.append("Terminaldeki `\(cliUse.link)` komutu bu uygulamaya bağlı; silersen komut çalışmaz")
            }
            if let days = date.days, days <= staleDays {
                cautions.append("Son \(staleDays) günde açtın; kullanmaya devam ediyorsan silme")
            } else if lastUsed == nil, let days = activityDays, days <= staleDays {
                cautions.append("Spotlight kaydı yok ama son \(days) günde kullanılmış (ayar/önbellek değişti)")
            }
        }

        var notes: [String] = cautions
        if lock == nil && cautions.isEmpty { notes.append("Yeniden indirilir") }
        if needsAuthorization { notes.append("macOS parola ya da Touch ID isteyecek") }
        notes.append(info.bundleID + (info.version.map { " \($0)" } ?? ""))
        if !leftovers.isEmpty || !named.isEmpty {
            notes.append("artıklar: \(leftovers.count) kesin, \(named.count) ad benzerliği")
        }
        if !twins.isEmpty {
            notes.append("aynı bundle id'li başka kopya kurulu (\(twins.map(\.path).joined(separator: ", "))); artıklar ortak olduğu için eklenmedi")
        }
        if info.isAppStore { notes.append("App Store'dan kurulmuş") }
        if !info.uninstallerHints.isEmpty {
            notes.append("kendi kaldırıcısı önerilir (\(info.uninstallerHints.joined(separator: ", ")))")
        }

        let appItem = CleanItem(
            category: .apps,
            name: info.name,
            path: bundle.path,
            allocatedBytes: sizes.first?.allocatedBytes ?? 0,
            risk: risk,
            dateSignal: date,
            lockReason: lock,
            note: notes.joined(separator: "; "),
            method: .trash,
            preselect: needsAuthorization || !cautions.isEmpty ? false : nil,
            needsAuthorization: needsAuthorization ? true : nil,
            leftoverBytes: leftovers.isEmpty ? nil : exactBytes
        )

        // Artıklar uygulamanın kilidini izler (çalışıyor, Cleaner, yapısal ret). Uygulama kırmızıysa (komut satırı
        // bağlantısı) artıkları en az sarı.
        let leftoverLock: String? = lock.map { "uygulama kilitli: \($0)" }
        func leftoverItem(_ url: URL, parent: String, m: SizeMeasurement, match: LeftoverMatch, key: String?,
                          hasGit: Bool = false, internalCommands: [String] = []) -> CleanItem {
            let label = parent.isEmpty ? "~" : (parent as NSString).lastPathComponent
            var note = match == .bundleID
                ? "\(info.name) uygulamasının verisi (\(label); bundle id ile eşleşti)"
                : "Adı benziyor; başka bir uygulamaya da ait olabilir (\(info.name), \(label))"
            if hasGit { note = Self.gitRepositoryNote + "; " + note }
            if !internalCommands.isEmpty { note = Self.internalCommandNote(internalCommands) + "; " + note }
            return CleanItem(
                category: .apps,
                name: "\(info.name): \(url.lastPathComponent)",
                path: url.path,
                allocatedBytes: m.allocatedBytes,
                risk: hasGit || !internalCommands.isEmpty ? .red : (match == .bundleID && risk != .red ? .green : .yellow),
                dateSignal: m.newestModification.map { .modified(days: DateSignal.days(from: $0, to: context.now)) } ?? .unknown,
                lockReason: leftoverLock,
                note: note,
                method: .trash,
                preselect: false,
                parentAppID: appItem.id,
                leftoverMatch: match,
                appBundleID: info.bundleID,
                matchedName: key
            )
        }
        var out = [appItem]
        for (l, m) in zip(leftovers, exactSizes) {
            out.append(leftoverItem(l.url, parent: l.parent, m: m, match: .bundleID, key: nil))
        }
        for (l, m) in zip(named, namedSizes) {
            out.append(leftoverItem(l.url, parent: l.parent, m: m, match: .name, key: l.key, hasGit: l.hasGitRepository,
                                    internalCommands: l.internalCommands))
        }
        return out
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
