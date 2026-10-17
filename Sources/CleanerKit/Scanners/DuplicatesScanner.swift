import Foundation

/// Mükerrer dosyalar: boyut → ilk N bayt özeti → tam özet (kademeli).
///
/// - İçerik YALNIZ `context.safeReader` ile okunur; bulut kökleri hiç gezilmez, dataless dosya listelenmez.
/// - Yeniden oluşan klasörler, paketler ve uygulama iç yapıları hariçtir.
/// - Her grupta bir "tutulacak" kopya vardır (`.info`, taşınamaz). Grup `groupID`, tutulacak kopya `keeperPath`
///   alanındadır; `Trasher` tutulacak kopyayı taşımaz ve bir grubun son kopyasını bırakmaz.
/// - Tutulacak olmayan kopyalar: yeşil ve seçili ("Aynısı duruyor"); git'te takipli kilitli;
///   Müzik/Fotoğraflar arşivi ve uygulama verisi sarı (seçili değil).
/// - Tutulacak kopyanın `allocatedBytes` değeri 0'dır (kazanç sayılmaz); boyutu notta yazar.
public struct DuplicatesScanner: Cleaner {
    public let id = "duplicates"
    public var categories: Set<Category> { [.duplicates] }

    /// En küçük dosya boyutu (bayt). Varsayılan 1 MB.
    public let minBytes: UInt64
    /// Ara özetin okuduğu ilk bayt sayısı.
    public let prefixBytes: Int
    /// Eşzamanlı özet sayısı (disk G/Ç için sınırlı).
    public let hashConcurrency: Int

    public init(minBytes: UInt64 = 1_048_576, prefixBytes: Int = 1_048_576, hashConcurrency: Int = 4) {
        self.minBytes = minBytes
        self.prefixBytes = prefixBytes
        self.hashConcurrency = max(1, hashConcurrency)
    }

    /// Yeniden oluşan ya da uygulama iç yapısı olan klasör adları (her derinlikte).
    static let skipDirNames: Set<String> = [
        "DerivedData", "node_modules", ".build", ".next", ".next-e2e", ".turbo", "build", "Pods", ".venv", "venv",
        "site-packages", "Caches", "CoreSimulator", ".npm", "pnpm", ".pnpm-store", ".cache", ".git", "vendor",
        ".gradle", ".m2", ".cargo", ".rustup", ".nvm", ".fnm", ".pyenv", ".rbenv", ".bun", "__pycache__",
        ".Trash", ".colima", ".docker", "workspaceStorage",
    ]

    struct Candidate: Sendable {
        var path: String
        var size: UInt64
        var mtime: TimeInterval
        var dev: dev_t
        var ino: UInt64
    }

    struct Group {
        var key: String
        var size: UInt64
        var members: [Candidate]
    }

    public func scan(_ context: ScanContext) async throws -> [CleanItem] {
        let home = PathUtil.canonicalDirectory(context.home)
        let walker = FileWalker(cloudGuard: context.cloudGuard, skipDirNames: Self.skipDirNames,
                                skipPaths: [FS.join(home, "Library"), FS.join(context.home.standardizedFileURL.path, "Library")])

        // 1) Dosyaları topla (yalnız meta veri).
        let candidates = try await collect(context: context, walker: walker)
        try context.checkCancellation()

        // 2) Aynı boyut.
        var bySize: [UInt64: [Candidate]] = [:]
        for c in candidates { bySize[c.size, default: []].append(c) }
        let sameSize = bySize.values.filter { $0.count > 1 }

        // 3) İlk N bayt özeti.
        let prefixBytes = self.prefixBytes
        let reader = context.safeReader
        var byPrefix: [[Candidate]] = []
        for group in sameSize {
            try context.checkCancellation()
            let hashes = try await boundedParallelMap(group, width: hashConcurrency) { c -> String? in
                try? reader.sha256Prefix(URL(fileURLWithPath: c.path), bytes: prefixBytes)
            }
            var buckets: [String: [Candidate]] = [:]
            for (c, h) in zip(group, hashes) { if let h { buckets[h, default: []].append(c) } }
            byPrefix.append(contentsOf: buckets.values.filter { $0.count > 1 })
        }

        // 4) Tam özet (önek dosyanın tamamını kapsıyorsa önek özeti yeterli).
        var groups: [Group] = []
        for group in byPrefix {
            try context.checkCancellation()
            let size = group[0].size
            let hashes: [String?]
            if size <= UInt64(prefixBytes) {
                hashes = try await boundedParallelMap(group, width: hashConcurrency) { c -> String? in
                    try? reader.sha256Prefix(URL(fileURLWithPath: c.path), bytes: prefixBytes)
                }
            } else {
                hashes = try await boundedParallelMap(group, width: hashConcurrency) { c -> String? in
                    try? reader.sha256(URL(fileURLWithPath: c.path))
                }
            }
            var buckets: [String: [Candidate]] = [:]
            for (c, h) in zip(group, hashes) { if let h { buckets[h, default: []].append(c) } }
            for (h, members) in buckets where members.count > 1 {
                groups.append(Group(key: String(h.prefix(12)), size: size, members: members))
            }
        }
        if groups.isEmpty { return [] }

        // 5) Git'te takipli olanlar.
        let tracked = try await trackedPaths(groups: groups, context: context)

        // 6) Öğeler.
        var items: [CleanItem] = []
        for group in groups.sorted(by: { ($0.size, $0.key) > ($1.size, $1.key) }) {
            try context.checkCancellation()
            items.append(contentsOf: try await makeItems(group, tracked: tracked, context: context))
        }
        return items
    }

    // MARK: - Toplama

    private func collect(context: ScanContext, walker: FileWalker) async throws -> [Candidate] {
        let min = Int64(minBytes)
        // Kök verilmemişse mükerrerin varsayılanı ana klasörün tamamıdır (projeler + Desktop dar kalır).
        let roots = context.roots(default: [context.home])
        var tops: [(FSInfo, dev_t)] = []
        var direct: [FSInfo] = []
        for root in roots {
            guard let info = walker.rootInfo(root) else { continue }
            if info.isRegular {
                if info.size >= min { direct.append(info) }
            } else if info.isDirectory {
                for child in try walker.children(of: info, rootDev: info.dev) {
                    if child.isDirectory { tops.append((child, info.dev)) } else if child.size >= min { direct.append(child) }
                }
            }
        }
        let lists = try await boundedParallelMap(tops, width: 8) { (top, dev) -> [FSInfo] in
            var out: [FSInfo] = []
            var stack = [top]
            while let dir = stack.popLast() {
                for child in try walker.children(of: dir, rootDev: dev) {
                    if child.isDirectory { stack.append(child) } else if child.size >= min { out.append(child) }
                }
            }
            return out
        }
        // Sabit bağlantılar (aynı dev+ino) ve çakışan kökler tek sayılır.
        var seen = Set<String>()
        var result: [Candidate] = []
        for f in direct + lists.flatMap({ $0 }) {
            guard seen.insert("\(f.dev):\(f.ino)").inserted else { continue }
            result.append(Candidate(path: f.path, size: UInt64(f.size), mtime: f.mtime, dev: f.dev, ino: f.ino))
        }
        return result.sorted { $0.path < $1.path }
    }

    // MARK: - Git

    /// Grup üyelerinden git'te takipli olanların yolları. Doğrulanamazsa (git yok/hata) takipli sayılır.
    private func trackedPaths(groups: [Group], context: ScanContext) async throws -> Set<String> {
        let homePath = PathUtil.canonicalDirectory(context.home)
        var repoOf: [String: String?] = [:] // klasör -> depo kökü
        func repoRoot(of dir: String) -> String? {
            if let cached = repoOf[dir] { return cached }
            var result: String?
            if FS.info(FS.join(dir, ".git")) != nil {
                result = dir
            } else if dir != "/", dir != homePath, !dir.isEmpty {
                result = repoRoot(of: (dir as NSString).deletingLastPathComponent)
            }
            repoOf[dir] = result
            return result
        }
        var byRepo: [String: [String]] = [:]
        for g in groups {
            for m in g.members {
                if let root = repoRoot(of: (m.path as NSString).deletingLastPathComponent) {
                    byRepo[root, default: []].append(m.path)
                }
            }
        }
        var tracked = Set<String>()
        for (root, paths) in byRepo.sorted(by: { $0.key < $1.key }) {
            try context.checkCancellation()
            guard context.cloudGuard.isSafeForGit(URL(fileURLWithPath: root)) else {
                tracked.formUnion(paths) // bulut deposunda git çalıştırılmaz; temkinli
                continue
            }
            let result = await context.signals.commands.run(
                "git", GitCommand.arguments(repo: root, ["ls-files", "-z"]), timeout: .seconds(60)
            )
            guard let result, result.succeeded else {
                tracked.formUnion(paths) // temkinli
                continue
            }
            let files = Set(result.stdout.split(separator: "\0", omittingEmptySubsequences: true).map { FS.join(root, String($0)) })
            for p in paths where files.contains(p) { tracked.insert(p) }
        }
        return tracked
    }

    // MARK: - Konum ve tutulacak seçimi

    enum Location: Int, Sendable {
        case tracked = -1, documents = 0, desktop = 1, other = 2, downloads = 3, archive = 4, appData = 5
    }

    static func location(of path: String, home: String, tracked: Bool) -> Location {
        if tracked { return .tracked }
        let prefix = home == "/" ? "/" : home + "/"
        guard path.hasPrefix(prefix) else { return .other }
        let first = path.dropFirst(prefix.count).split(separator: "/").first.map(String.init) ?? ""
        if first.hasPrefix(".") || first == "Library" { return .appData }
        switch first {
        case "Documents": return .documents
        case "Desktop": return .desktop
        case "Downloads": return .downloads
        case "Music", "Pictures": return .archive
        default: return .other
        }
    }

    /// Tutulacak kopya sırası: konum (proje/Belgeler > Masaüstü > diğer > İndirilenler > arşiv > uygulama verisi),
    /// sonra en eski değişiklik tarihi (saniye), sonra en kısa ad, sonra yol. Kopyalar çoğu zaman sonradan
    /// oluşur; en eski olan asıl dosyadır (ör. `odaglan.png` ile sonradan inen `evrak.png`).
    static func keeperOrder(_ a: Candidate, _ b: Candidate, la: Int, lb: Int) -> Bool {
        if la != lb { return la < lb }
        let (ta, tb) = (a.mtime.rounded(.down), b.mtime.rounded(.down))
        if ta != tb { return ta < tb }
        let (na, nb) = ((a.path as NSString).lastPathComponent, (b.path as NSString).lastPathComponent)
        if na.count != nb.count { return na.count < nb.count }
        return a.path < b.path
    }

    /// Tutulmayan kopyanın riski ve kilidi: git'te takipli kilitli; arşiv ve uygulama verisi sarı; diğerleri yeşil.
    static func nonKeeperRisk(_ l: Location) -> (Risk, String?) {
        switch l {
        case .tracked: (.green, "Git deposunda takipli")
        case .archive, .appData: (.yellow, nil)
        default: (.green, nil)
        }
    }

    private func makeItems(_ group: Group, tracked: Set<String>, context: ScanContext) async throws -> [CleanItem] {
        let home = PathUtil.canonicalDirectory(context.home)
        let homeAlt = context.home.standardizedFileURL.path
        func loc(_ c: Candidate) -> Location {
            let l = Self.location(of: c.path, home: home, tracked: tracked.contains(c.path))
            if l == .other, c.path.hasPrefix(homeAlt + "/") {
                return Self.location(of: c.path, home: homeAlt, tracked: false)
            }
            return l
        }
        let ranked = group.members.sorted { a, b in
            Self.keeperOrder(a, b, la: loc(a).rawValue, lb: loc(b).rawValue)
        }
        let keeper = ranked[0]
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(group.size), countStyle: .file)
        // Kullanıcı "Bunu tut" ile başka kopyayı seçerse bu kopyanın alacağı risk ve kilit (tutulmayan kopya kuralı).
        let (keeperRisk, keeperLock) = Self.nonKeeperRisk(loc(keeper))
        let keeperBytes = try await context.sizeMeter.measure(URL(fileURLWithPath: keeper.path)).allocatedBytes
        var items: [CleanItem] = []
        var keeperItem = CleanItem(
            category: .duplicates,
            name: (keeper.path as NSString).lastPathComponent,
            path: keeper.path,
            allocatedBytes: 0,
            risk: .info,
            dateSignal: context.signals.dateSignal(for: URL(fileURLWithPath: keeper.path), now: context.now),
            note: "Tutulacak kopya (\(group.members.count) kopyadan biri, \(sizeText)).",
            method: .none,
            groupID: group.key,
            keeperPath: keeper.path
        )
        keeperItem.ifNotKeptRisk = keeperRisk
        keeperItem.ifNotKeptLockReason = keeperLock
        keeperItem.ifNotKeptBytes = keeperBytes
        items.append(keeperItem)
        for c in ranked.dropFirst() {
            try context.checkCancellation()
            let url = URL(fileURLWithPath: c.path)
            let m = try await context.sizeMeter.measure(url)
            let l = loc(c)
            let (risk, lock) = Self.nonKeeperRisk(l)
            var note = "Aynısı duruyor: \(keeper.path)"
            switch l {
            case .archive: note += " · Müzik/Fotoğraflar arşivindeki kopya; otomatik seçilmez."
            case .appData: note += " · Uygulama verisi; otomatik seçilmez."
            default: break
            }
            items.append(CleanItem(
                category: .duplicates,
                name: (c.path as NSString).lastPathComponent,
                path: c.path,
                allocatedBytes: m.allocatedBytes,
                risk: risk,
                dateSignal: context.signals.dateSignal(for: url, now: context.now),
                lockReason: lock,
                note: note,
                method: .trash,
                groupID: group.key,
                keeperPath: keeper.path
            ))
        }
        return items
    }
}
