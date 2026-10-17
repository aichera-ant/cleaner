import Foundation

/// Çöp Kutusu raporu.
public struct TrashReport: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        /// Çöp Kutusu'na taşındı (dry-run'da: taşınacaktı).
        case trashed
        /// Komut çalıştırıldı (dry-run'da: çalıştırılacaktı).
        case command
    }

    public struct Done: Codable, Sendable, Equatable {
        public var id: String
        public var path: String
        public var bytes: UInt64
        public var action: Action
        /// Çöp Kutusu'ndaki yeni yol ya da komut çıktısı özeti.
        public var detail: String?
    }

    public struct Refused: Codable, Sendable, Equatable {
        public var id: String
        public var path: String
        public var reason: String

        public init(id: String, path: String, reason: String) {
            self.id = id
            self.path = path
            self.reason = reason
        }
    }

    public var dryRun: Bool
    public var done: [Done]
    public var refused: [Refused]
    /// Ret değil: üst öğesi aynı çalıştırmada taşındığı için ayrıca işlenmeyenler (toplama girmez).
    public var skipped: [Refused] = []

    public init(dryRun: Bool, done: [Done], refused: [Refused], skipped: [Refused] = []) {
        self.dryRun = dryRun
        self.done = done
        self.refused = refused
        self.skipped = skipped
    }

    public var totalBytes: UInt64 { done.reduce(0) { $0 &+ $1.bytes } }
}

/// Seçilen öğeleri Çöp Kutusu'na taşır ya da komutlarını çalıştırır. Kalıcı silme yapmaz.
///
/// Reddedilenler: kilitli öğe, `.info` risk, `.none` yöntem, korunan yol, ana klasör dışı, git deposu kökü,
/// var olmayan yol. Varsayılan dry-run: hiçbir şey taşınmaz, yalnız rapor üretilir.
///
/// Uygulama istisnası (`apps` kategorisi): `PathPolicy.appBundleRejectionReason` + Apple (`com.apple.*`) değil
/// + Cleaner'ın kendisi değil + çalışmıyor (yol, bundle id ya da ad ile). Artıklar (`relatedPaths`) paketten
/// SONRA taşınır; paket taşınamazsa artıklara dokunulmaz.
///
/// Yetkili taşıma (`privilegedRecycler`, gerçekte `FinderRecycler`: Finder parola/Touch ID ister): YALNIZ
/// taze taramada `needsAuthorization == true` olan `apps` öğesinin `.app` paketi için, dar istisna taşıma anında
/// yeniden doğrulanınca (yazma sorunu yalnız yetkiyle aşılabilen türdense) kullanılır. Başka hiçbir yol (artıklar
/// dahil) yetkili taşıyıcıya verilmez; artıklar normal taşıyıcıyla, mevcut kurallarla taşınır. Yetkili taşıyıcı
/// verilmemişse (CLI) bu öğeler reddedilir.
public struct Trasher: Sendable {
    public let policy: PathPolicy
    public let commands: any CommandRunning
    /// Uygulama taşımadan hemen önce "çalışıyor mu?" kontrolü için.
    public let processes: any ProcessListing
    public var commandTimeout: Duration
    /// Normal taşıyıcı. Gerçekte `FileManagerRecycler`; testte geçici klasöre taşıyan sahte verilir
    /// (gerçek Çöp Kutusu'na dokunulmasın diye).
    let recycler: any Recycling
    /// Yetkili taşıyıcı (yalnız `needsAuthorization` uygulama paketi için). nil: bu öğeler reddedilir.
    let privilegedRecycler: (any Recycling)?
    /// Cleaner'ın kendi çalıştırılabilir dosyası ve bundle id'si: kendi paketini taşımasın.
    let selfExecutable: URL?
    let selfBundleID: String?

    /// - Parameters:
    ///   - recycler: normal taşıyıcı (varsayılan `FileManager.trashItem`).
    ///   - privilegedRecycler: yetkili taşıyıcı (arayüz `FinderRecycler` verir; CLI vermez).
    public init(policy: PathPolicy, commands: any CommandRunning, processes: any ProcessListing = LiveProcessLister(),
                commandTimeout: Duration = .seconds(600), recycler: any Recycling = FileManagerRecycler(),
                privilegedRecycler: (any Recycling)? = nil) {
        self.init(policy: policy, commands: commands, processes: processes, commandTimeout: commandTimeout,
                  selfExecutable: Bundle.main.executableURL, selfBundleID: Bundle.main.bundleIdentifier,
                  recycler: recycler, privilegedRecycler: privilegedRecycler)
    }

    init(policy: PathPolicy, commands: any CommandRunning, processes: any ProcessListing = LiveProcessLister(),
         commandTimeout: Duration = .seconds(600),
         selfExecutable: URL? = Bundle.main.executableURL, selfBundleID: String? = Bundle.main.bundleIdentifier,
         recycler: any Recycling, privilegedRecycler: (any Recycling)? = nil) {
        self.policy = policy
        self.commands = commands
        self.processes = processes
        self.commandTimeout = commandTimeout
        self.selfExecutable = selfExecutable
        self.selfBundleID = selfBundleID
        self.recycler = recycler
        self.privilegedRecycler = privilegedRecycler
    }

    /// Test kolaylığı: kapanışla taşıyan normal taşıyıcı.
    init(policy: PathPolicy, commands: any CommandRunning, processes: any ProcessListing = LiveProcessLister(),
         commandTimeout: Duration = .seconds(600),
         selfExecutable: URL? = Bundle.main.executableURL, selfBundleID: String? = Bundle.main.bundleIdentifier,
         mover: @escaping @Sendable (URL) throws -> URL?, privilegedRecycler: (any Recycling)? = nil) {
        self.init(policy: policy, commands: commands, processes: processes, commandTimeout: commandTimeout,
                  selfExecutable: selfExecutable, selfBundleID: selfBundleID,
                  recycler: ClosureRecycler(body: mover), privilegedRecycler: privilegedRecycler)
    }

    /// Öğe yetkili taşıyıcıyla mı taşınacak? Yalnız taze taramada `needsAuthorization` olan uygulama öğesi ve
    /// yetkili taşıyıcı verilmişse.
    func usesPrivilegedRecycler(_ item: CleanItem) -> Bool {
        item.category == .apps && item.needsAuthorization == true && privilegedRecycler != nil
    }

    static let authorizationRefusal = "Uygulama Yönetimi koruması: Cleaner uygulamasından kaldırın"

    /// Bir uygulama öğesinin en fazla kaç artığı olabilir (bozuk/elle değiştirilmiş öğeye karşı sınır).
    static let maxRelatedPaths = 32

    /// Öğe neden reddedilir? Reddedilmiyorsa nil.
    public func rejectionReason(for item: CleanItem) -> String? {
        if item.isLocked { return "kilitli: \(item.lockReason ?? "kullanımda")" }
        if item.risk == .info { return "yalnız bilgi" }
        if item.method == .none { return "temizleme yöntemi yok" }
        // Öğe kimliği yoluyla tutarlı olmalı (elle değiştirilmiş öğe ile başka yol taşınmasın).
        if item.id != CleanItem.makeID(path: item.path) { return "id ile yol uyuşmuyor" }
        if let reason = groupFieldRejection(item) { return reason }
        if item.needsAuthorization == true {
            guard item.category == .apps else { return "yetki işareti yalnız uygulama öğesinde olabilir" }
            guard privilegedRecycler != nil else { return Trasher.authorizationRefusal }
        }
        if item.category == .apps, item.method != .trash { return "uygulama yalnız Çöp Kutusu'na taşınır" }
        switch item.method {
        case .none:
            return "temizleme yöntemi yok"
        case .command:
            if item.relatedPaths != nil { return "ilişkili yollar yalnız uygulama öğesinde olabilir" }
            if case .failure(let r) = CommandPolicy.validate(item, policy: policy) { return r.reason }
            return nil
        case .trash:
            if item.path == "/docker" || item.path.hasPrefix("/docker/") {
                return "docker öğesi Çöp Kutusu'na gönderilmez (yalnız docker komutuyla)"
            }
            return pathRejectionReason(for: item)
        }
    }

    /// Mükerrer alanları yalnız `duplicates` öğesinde olabilir; tutulacak kopya taşınmaz.
    func groupFieldRejection(_ item: CleanItem) -> String? {
        guard item.groupID != nil || item.keeperPath != nil else { return nil }
        guard item.category == .duplicates else { return "grup bilgisi yalnız mükerrer öğesinde olabilir" }
        guard item.groupID != nil, let keeper = item.keeperPath else { return "mükerrer grup bilgisi eksik" }
        if PathUtil.key(PathUtil.canonical(URL(fileURLWithPath: keeper))) == PathUtil.key(PathUtil.canonical(item.url)) {
            return "grubun tutulacak kopyası"
        }
        return nil
    }

    /// Yol düzeyindeki kontroller (Çöp Kutusu yöntemi; taşımadan hemen önce yeniden çağrılır).
    func pathRejectionReason(for item: CleanItem) -> String? {
        if item.category == .apps {
            guard item.method == .trash else { return "uygulama yalnız Çöp Kutusu'na taşınır" }
            return appRejectionReason(for: item)
        }
        if item.relatedPaths != nil { return "ilişkili yollar yalnız uygulama öğesinde olabilir" }
        return policy.trashRejectionReason(for: item.url)
    }

    /// Tarama sonucuna göre ret: öğenin alt ağacında (ilişkili yollar dahil) kilitli ya da yalnız bilgi
    /// (tutulacak mükerrer kopya dahil) başka bir öğe varsa öğe taşınmaz.
    /// `item` tarama öğesinin kendisidir (id'ler taramada tekildir; belirsiz id önceden reddedilir).
    func scanContextRejection(_ item: CleanItem, scanItems: [CleanItem]) -> String? {
        let mine = item.footprint.map { PathUtil.canonicalKey($0) }
        for other in scanItems where other.id != item.id && (other.isLocked || other.risk == .info) {
            for k in other.footprint.map({ PathUtil.canonicalKey($0) }) where mine.contains(where: { PathUtil.isSameOrDescendant(k, of: $0) }) {
                return "İçinde kullanımdaki ya da tutulacak öğe var: \(other.path)"
            }
        }
        return nil
    }

    /// Dışarıdan gelen öğe, aynı id'li tarama öğesiyle güvenlikle ilgili bütün alanlarda aynı mı?
    static func matchesScan(_ item: CleanItem, _ scanned: CleanItem) -> Bool {
        item.id == scanned.id && item.path == scanned.path && item.category == scanned.category
            && item.risk == scanned.risk && item.lockReason == scanned.lockReason && item.method == scanned.method
            && item.groupID == scanned.groupID && item.keeperPath == scanned.keeperPath
            && item.isDuplicateKeeper == scanned.isDuplicateKeeper && item.relatedPaths == scanned.relatedPaths
            && item.preselect == scanned.preselect && item.needsAuthorization == scanned.needsAuthorization
            && item.ifNotKeptRisk == scanned.ifNotKeptRisk && item.ifNotKeptLockReason == scanned.ifNotKeptLockReason
            && item.ifNotKeptBytes == scanned.ifNotKeptBytes
    }

    /// id -> tarama öğesi. Taramada birden çok kez geçen id belirsizdir (`ambiguous`), hiçbiri kullanılmaz.
    static func index(_ scan: [CleanItem]) -> (byID: [String: CleanItem], ambiguous: Set<String>) {
        var byID: [String: CleanItem] = [:]
        var ambiguous = Set<String>()
        for item in scan {
            if byID[item.id] != nil { ambiguous.insert(item.id) } else { byID[item.id] = item }
        }
        return (byID, ambiguous)
    }

    /// Uygulama öğesi taşınamıyorsa nedeni.
    func appRejectionReason(for item: CleanItem) -> String? {
        appCheck(for: item).reason
    }

    /// Uygulama kontrolü; geçerse doğrulanmış bundle id'yi de döner (artıklar taşınırken yeniden kullanılır).
    func appCheck(for item: CleanItem) -> (reason: String?, bundleID: String?) {
        // Yetki yalnız taze taramada işaretli öğede ve yetkili taşıyıcı varken tolere edilir; diğer bütün koşullar aynı.
        if let reason = policy.appBundleRejectionReason(for: item.url, allowingAuthorization: usesPrivilegedRecycler(item)) {
            return (reason, nil)
        }
        let reader = SafeReader(cloudGuard: CloudGuard(home: policy.home))
        guard let info = AppBundleInfo.read(item.url, reader: reader) else {
            return ("Info.plist okunamadı ya da bundle id geçersiz", nil)
        }
        return (appInfoRejectionReason(for: item, info: info, reader: reader), info.bundleID)
    }

    private func appInfoRejectionReason(for item: CleanItem, info: AppBundleInfo, reader: SafeReader) -> String? {
        if info.isApple { return "Apple sistem uygulaması" }
        if isSelf(bundle: item.url, bundleID: info.bundleID) { return "Cleaner'ın kendisi" }
        let running = RunningApps(processes: processes.runningProcesses(), reader: reader)
        if running.isRunning(bundle: item.url, bundleID: info.bundleID) || processes.isRunning(info.name) {
            return "çalışıyor"
        }
        let related = item.relatedPaths ?? []
        if related.count > Trasher.maxRelatedPaths { return "çok fazla ilişkili yol" }
        // Aynı bundle id'li başka kopya kuruluysa artıklar ortaktır; artıklı öğe taşınmaz.
        if !related.isEmpty,
           let other = AppsScanner.otherBundles(withID: info.bundleID, excluding: item.url, appRoots: policy.appRoots, reader: reader).first {
            return "aynı bundle id'li başka kopya kurulu (\(other.path)); artıklar ortak"
        }
        for r in related {
            if let why = policy.leftoverRejectionReason(for: URL(fileURLWithPath: r), bundleID: info.bundleID) {
                return "artık reddedildi (\(r)): \(why)"
            }
        }
        return nil
    }

    func isSelf(bundle: URL, bundleID: String) -> Bool {
        if let selfBundleID, selfBundleID.lowercased() == bundleID.lowercased() { return true }
        if let selfExecutable {
            let exe = PathUtil.key(PathUtil.canonical(selfExecutable))
            let b = PathUtil.key(PathUtil.canonical(bundle))
            if PathUtil.isSameOrDescendant(exe, of: b) { return true }
        }
        return false
    }

    /// Taşıma hatası için okunur neden.
    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        let permission = (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteNoPermissionError)
            || (ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)))
            || ((ns.userInfo[NSUnderlyingErrorKey] as? NSError).map {
                $0.domain == NSPOSIXErrorDomain && ($0.code == Int(EPERM) || $0.code == Int(EACCES))
            } ?? false)
        return permission ? "izin yok (yönetici izni gerekir): \(error.localizedDescription)"
            : error.localizedDescription
    }

    /// Ana giriş: tarama sonucundaki id'leri taşır (dry-run'da yalnız raporlar).
    ///
    /// Arayüz YALNIZ bu girişi kullanır ve `scan` olarak bellekte tuttuğu taze `ScanEngine` sonucunu verir.
    /// JSON'dan (diskten, başka süreçten) okunan tarama sonucu ne buraya ne `trash(_:scanItems:)`'a verilir.
    ///
    /// Güvenilir kaynak yalnız `scan`'dir (aynı taramanın bütün öğeleri): her id tarama öğesine çözülür ve bütün
    /// kararlar o öğenin alanlarıyla verilir. Taramada olmayan ya da birden çok kez geçen id reddedilir.
    /// Alt ağacında kilitli/bilgi öğesi olan öğe reddedilir. Aynı çalıştırmada hem üst hem alt öğe seçilirse alt öğe
    /// "üst öğeyle birlikte taşınıyor" diye atlanır (ret değildir, toplama girmez). Bir mükerrer grubunun hiç
    /// kopyası kalmayacaksa bir kopya kalacak şekilde ret yapılır.
    ///
    /// - Parameter keepers: mükerrer "Bunu tut" seçimi (groupID → tutulacak yol). Yol o grubun bu taramadaki bir
    ///   üyesi değilse grubun seçilen bütün öğeleri reddedilir. Tutulan kopya taşınmaz (bilgi öğesi sayılır, onu
    ///   içeren üst öğe de taşınmaz); taramanın varsayılan tutulacak kopyası artık taşınabilir (tarayıcının
    ///   `ifNotKeptRisk`/`ifNotKeptLockReason` değeriyle; kilitliyse yine taşınmaz). Son kopya kuralı aynen geçerli.
    public func trash(ids: [String], scan: [CleanItem], dryRun: Bool = true,
                      keepers: [String: String] = [:]) async -> TrashReport {
        var report = TrashReport(dryRun: dryRun, done: [], refused: [])
        let (scan, invalidGroups) = Trasher.applyKeepers(keepers, to: scan)
        let (byID, ambiguous) = Trasher.index(scan)
        var selected: [CleanItem] = []
        var seen = Set<String>()
        for id in ids {
            guard seen.insert(id).inserted else { continue }
            guard !ambiguous.contains(id) else {
                report.refused.append(.init(id: id, path: "", reason: "taramada birden çok aynı id"))
                continue
            }
            guard let scanned = byID[id] else {
                report.refused.append(.init(id: id, path: "", reason: "bu taramada bulunamadı"))
                continue
            }
            if let g = scanned.groupID, let why = invalidGroups[g] {
                report.refused.append(.init(id: id, path: scanned.path, reason: why))
                continue
            }
            selected.append(scanned)
        }
        return await run(selected, scan: scan, dryRun: dryRun, report: report)
    }

    /// Öğe listesiyle giriş (CLI ve testler). Öğeler güvenilmez: her öğe id'siyle `scanItems`'taki
    /// tarama öğesine eşlenir; eşleşmeyen ya da güvenlikle ilgili herhangi bir alanı (yol, kategori, risk, kilit,
    /// yöntem, grup alanları, ilişkili yollar, ön seçim, yetki) farklı olan reddedilir. Kararlar tarama öğesiyle
    /// verilir. `scanItems` taze tarama olmalıdır; arayüz bu girişi kullanmaz (`trash(ids:scan:)`), JSON'dan
    /// okunan tarama sonucu `scanItems` olarak verilmez. `keepers`: `trash(ids:scan:keepers:)` ile aynı.
    public func trash(_ items: [CleanItem], dryRun: Bool = true, scanItems: [CleanItem],
                      keepers: [String: String] = [:]) async -> TrashReport {
        var report = TrashReport(dryRun: dryRun, done: [], refused: [])
        let (byID, ambiguous) = Trasher.index(scanItems)
        var ids: [String] = []
        var seen = Set<String>()
        for item in items {
            guard seen.insert(item.id).inserted else { continue }
            if let scanned = byID[item.id], !ambiguous.contains(item.id), !Trasher.matchesScan(item, scanned) {
                report.refused.append(.init(id: item.id, path: item.path, reason: "öğe tarama sonucundan farklı"))
                continue
            }
            ids.append(item.id)
        }
        let rest = await trash(ids: ids, scan: scanItems, dryRun: dryRun, keepers: keepers)
        report.done += rest.done
        report.refused += rest.refused
        report.skipped += rest.skipped
        return report
    }

    /// `selected`: tarama öğeleri (güvenilir).
    private func run(_ selected: [CleanItem], scan: [CleanItem], dryRun: Bool, report initial: TrashReport) async -> TrashReport {
        var report = initial
        var accepted: [CleanItem] = []
        for item in selected {
            if let reason = rejectionReason(for: item) ?? scanContextRejection(item, scanItems: scan) {
                report.refused.append(.init(id: item.id, path: item.path, reason: reason))
                continue
            }
            accepted.append(item)
        }
        accepted = applyGroupRule(accepted, scanItems: scan, report: &report)

        // Üst öğeler önce: alt öğe, üst öğesi bu çalıştırmada taşındıysa atlanır.
        let ordered = accepted.enumerated().sorted { a, b in
            let (da, db) = (Trasher.depth(a.element.path), Trasher.depth(b.element.path))
            return da != db ? da < db : a.offset < b.offset
        }.map(\.element)
        var coveredKeys: [(key: String, path: String)] = []
        for item in ordered {
            let isVirtual = item.path.hasPrefix("/docker/")
            if !isVirtual {
                let k = PathUtil.canonicalKey(item.path)
                if let parent = coveredKeys.first(where: { PathUtil.isSameOrDescendant(k, of: $0.key) }) {
                    report.skipped.append(.init(id: item.id, path: item.path, reason: "üst öğeyle birlikte taşınıyor: \(parent.path)"))
                    continue
                }
            }
            if await process(item, dryRun: dryRun, report: &report), !isVirtual {
                coveredKeys += item.footprint.map { (PathUtil.canonicalKey($0), item.path) }
            }
        }
        return report
    }

    static func depth(_ path: String) -> Int { path.split(separator: "/").count }

    /// "Bunu tut" seçimini taramaya uygular. Dönüş: düzenlenmiş tarama ve seçimi geçersiz grupların ret nedeni.
    /// Yeni tutulacak kopya bilgi öğesi olur (taşınmaz, üst öğesini bloklar); eski tutulacak kopya tarayıcının
    /// `ifNotKept*` değerleriyle taşınabilir öğe olur (varsayılan seçimde değil); diğerlerinin `keeperPath`'i değişir.
    static func applyKeepers(_ keepers: [String: String], to scan: [CleanItem]) -> (items: [CleanItem], invalid: [String: String]) {
        guard !keepers.isEmpty else { return (scan, [:]) }
        var items = scan
        var invalid: [String: String] = [:]
        for (g, wanted) in keepers.sorted(by: { $0.key < $1.key }) {
            let idx = items.indices.filter { items[$0].groupID == g && items[$0].category == .duplicates }
            guard !idx.isEmpty else { continue } // grup bu taramada yok: id'leri zaten bulunamaz
            let key = PathUtil.canonicalKey(wanted)
            guard let k = idx.first(where: { PathUtil.canonicalKey(items[$0].path) == key }) else {
                invalid[g] = "tutulacak kopya bu mükerrer grubunun üyesi değil: \(wanted)"
                continue
            }
            if items[k].isDuplicateKeeper { continue } // zaten varsayılan
            let newKeeper = items[k].path
            for i in idx {
                if i == k {
                    items[i].risk = .info
                    items[i].method = .none
                    items[i].preselect = false
                } else if items[i].isDuplicateKeeper {
                    items[i].method = .trash
                    items[i].lockReason = items[i].ifNotKeptLockReason
                    items[i].risk = items[i].lockReason != nil ? .locked : (items[i].ifNotKeptRisk ?? .yellow)
                    items[i].preselect = false
                    items[i].allocatedBytes = Trasher.allocatedBytes(items[i].path)
                    items[i].ifNotKeptRisk = nil
                    items[i].ifNotKeptLockReason = nil
                    items[i].ifNotKeptBytes = nil
                }
                items[i].keeperPath = newKeeper
            }
        }
        return (items, invalid)
    }

    /// Dosyanın ayrılan boyutu (yalnız `lstat`; içerik okunmaz). Yoksa 0.
    static func allocatedBytes(_ path: String) -> UInt64 {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_blocks > 0 else { return 0 }
        return UInt64(st.st_blocks) &* 512
    }

    /// Mükerrer grupları: taşıma sonunda grubun en az bir kopyası (diskte var olan, taşınmayan) kalmalı.
    /// Kabul edilen herhangi bir öğenin (ilişkili yollar dahil) altında kalan kopya da taşınıyor sayılır.
    /// Kalmayacaksa: önce seçilen ve başka bir kabul edilen öğece kapsanmayan (diskte var olan) son kopya
    /// reddedilir; böyle kopya yoksa diskte var olan bir kopyayı kapsayan bütün öğeler (üst klasörler ve kopyanın
    /// kendisi) reddedilir. Hiçbir kopya diskte yoksa grubun seçilen son öğesi reddedilir.
    private func applyGroupRule(_ accepted: [CleanItem], scanItems: [CleanItem], report: inout TrashReport) -> [CleanItem] {
        var rejected = Set<String>()
        // Komut öğeleri de temkinli olarak kapsayan sayılır; docker sanal yolları hariç.
        let keysByID: [String: [String]] = Dictionary(accepted.map { item in
            (item.id, item.path.hasPrefix("/docker/") ? [] : item.footprint.map { PathUtil.canonicalKey($0) })
        }, uniquingKeysWith: { a, _ in a })
        let allKeys = keysByID.values.flatMap { $0 }
        // Seçilen öğelerin grupları + kopyası (ya da tutulacağı) seçilen bir üst öğenin altında kalan gruplar.
        var groups = Set(accepted.compactMap(\.groupID))
        for i in scanItems {
            guard let g = i.groupID, !groups.contains(g) else { continue }
            let keys = ([i.path] + (i.keeperPath.map { [$0] } ?? [])).map { PathUtil.canonicalKey($0) }
            if keys.contains(where: { k in allKeys.contains { PathUtil.isSameOrDescendant(k, of: $0) } }) {
                groups.insert(g)
            }
        }
        guard !groups.isEmpty else { return accepted }
        func coverers(_ key: String) -> [CleanItem] {
            accepted.filter { item in
                !rejected.contains(item.id)
                    && (keysByID[item.id] ?? []).contains { PathUtil.isSameOrDescendant(key, of: $0) }
            }
        }
        func exists(_ path: String) -> Bool {
            var st = stat()
            return lstat(path, &st) == 0
        }
        func reject(_ item: CleanItem, _ reason: String) {
            guard rejected.insert(item.id).inserted else { return }
            report.refused.append(.init(id: item.id, path: item.path, reason: reason))
        }
        let lastCopy = "mükerrer grubunun son kopyası; en az bir kopya kalmalı"
        for g in groups.sorted() {
            // Grubun bilinen bütün kopyaları: anahtar -> gerçek yol.
            var members: [String: String] = [:]
            for i in scanItems where i.groupID == g { members[PathUtil.canonicalKey(i.path)] = i.path }
            for i in accepted where i.groupID == g {
                members[PathUtil.canonicalKey(i.path)] = i.path
                if let k = i.keeperPath { members[PathUtil.canonicalKey(k)] = k }
            }
            let existing = members.filter { exists($0.value) }.sorted { $0.value < $1.value }
            if existing.contains(where: { coverers($0.key).isEmpty }) { continue } // bir kopya kalıyor
            let selected = accepted.filter { $0.groupID == g && !rejected.contains($0.id) }
            // 1) Kendisinden başka hiçbir öğece kapsanmayan seçilen kopya: yalnız onu reddetmek yeter.
            if let pick = selected.last(where: { s in
                exists(s.path) && coverers(PathUtil.canonicalKey(s.path)).allSatisfy { $0.id == s.id }
            }) {
                reject(pick, lastCopy)
                continue
            }
            // 2) Var olan bir kopyayı (en az öğece kapsananı) kapsayan her şey reddedilir.
            if let keep = existing.min(by: { coverers($0.key).count < coverers($1.key).count }) {
                for c in coverers(keep.key) {
                    let own = c.groupID == g && PathUtil.canonicalKey(c.path) == keep.key
                    reject(c, own ? lastCopy : "içinde mükerrer grubunun son kopyası var: \(keep.value)")
                }
                continue
            }
            // 3) Hiçbir kopya diskte yok.
            if let last = selected.last { reject(last, lastCopy) }
        }
        return accepted.filter { !rejected.contains($0.id) }
    }

    /// Tek öğeyi işler. Başarılıysa (dry-run'da kabul edildiyse) true.
    private func process(_ item: CleanItem, dryRun: Bool, report: inout TrashReport) async -> Bool {
        switch item.method {
        case .none:
            return false // rejectionReason yakalar
        case .command(let cmd):
            // Taşımadan hemen önce yeniden doğrula; kurulan biçim çalışır, öğedeki metin değil.
            let exec: CommandPolicy.Exec
            switch CommandPolicy.validate(item, policy: policy) {
            case .failure(let r):
                report.refused.append(.init(id: item.id, path: item.path, reason: r.reason))
                return false
            case .success(let e): exec = e
            }
            if dryRun {
                report.done.append(.init(id: item.id, path: item.path, bytes: item.allocatedBytes, action: .command, detail: cmd))
                return true
            }
            let result: CommandResult? = switch exec {
            case .argv(let tool, let args): await commands.run(tool, args, timeout: commandTimeout)
            case .shell(let line): await commands.runShell(line, timeout: commandTimeout)
            }
            guard let result else {
                report.refused.append(.init(id: item.id, path: item.path, reason: "komut çalıştırılamadı: \(cmd)"))
                return false
            }
            if result.succeeded {
                report.done.append(.init(id: item.id, path: item.path, bytes: item.allocatedBytes, action: .command, detail: cmd))
                return true
            }
            let why = result.timedOut ? "zaman aşımı" : "çıkış kodu \(result.exitCode)"
            report.refused.append(.init(id: item.id, path: item.path, reason: "komut başarısız (\(why)): \(cmd)"))
            return false
        case .trash:
            if dryRun {
                report.done.append(.init(id: item.id, path: item.path, bytes: item.allocatedBytes, action: .trashed, detail: nil))
                if item.category == .apps, let id = appCheck(for: item).bundleID {
                    await appendLeftovers(item, bundleID: id, dryRun: true, to: &report)
                }
                return true
            }
            // Taşımadan hemen önce son kontrol (tarama ile taşıma arasında yol değişmiş olabilir).
            var verifiedBundleID: String?
            if item.category == .apps {
                let check = appCheck(for: item)
                if let reason = check.reason {
                    report.refused.append(.init(id: item.id, path: item.path, reason: reason))
                    return false
                }
                verifiedBundleID = check.bundleID
            } else if let reason = pathRejectionReason(for: item) {
                report.refused.append(.init(id: item.id, path: item.path, reason: reason))
                return false
            }
            // Yetkili taşıyıcı yalnız burada, yalnız doğrulanmış `needsAuthorization` uygulama paketi için.
            var mover = recycler
            if item.category == .apps, verifiedBundleID != nil, usesPrivilegedRecycler(item), let privileged = privilegedRecycler {
                mover = privileged
            }
            do {
                let resulting = try await mover.recycle(item.url)
                report.done.append(.init(id: item.id, path: item.path, bytes: item.allocatedBytes, action: .trashed, detail: resulting?.path))
            } catch {
                // Paket taşınamadıysa artıklarına dokunulmaz.
                report.refused.append(.init(id: item.id, path: item.path, reason: "taşınamadı: \(Trasher.describe(error))"))
                return false
            }
            if let verifiedBundleID {
                await appendLeftovers(item, bundleID: verifiedBundleID, dryRun: false, to: &report)
            }
            return true
        }
    }

    /// Uygulama artıkları: ana paketten sonra, her biri ayrı ayrı son kontrolle. Boyutları ana öğenin
    /// boyutuna dahil olduğundan kendi satırları 0 bayttır. Bu arada silinmiş artık sessizce atlanır.
    /// `bundleID`: paket taşınmadan hemen önce Info.plist'ten doğrulanan kimlik.
    private func appendLeftovers(_ item: CleanItem, bundleID: String, dryRun: Bool, to report: inout TrashReport) async {
        guard item.category == .apps, let related = item.relatedPaths else { return }
        for r in related {
            let url = URL(fileURLWithPath: r)
            if let why = policy.leftoverRejectionReason(for: url, bundleID: bundleID) ?? policy.trashRejectionReason(for: url) {
                if why == "yol yok" { continue }
                report.refused.append(.init(id: item.id, path: r, reason: "artık: \(why)"))
                continue
            }
            if dryRun {
                report.done.append(.init(id: item.id, path: r, bytes: 0, action: .trashed, detail: "artık"))
                continue
            }
            do {
                // Artıklar her zaman normal taşıyıcıyla (yetkili taşıyıcı ana klasör yollarına verilmez).
                let resulting = try await recycler.recycle(url)
                report.done.append(.init(id: item.id, path: r, bytes: 0, action: .trashed, detail: resulting?.path))
            } catch {
                report.refused.append(.init(id: item.id, path: r, reason: "artık taşınamadı: \(Trasher.describe(error))"))
            }
        }
    }
}
