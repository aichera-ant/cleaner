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
public struct Trasher: Sendable {
    public let policy: PathPolicy
    public let commands: any CommandRunning
    /// Uygulama taşımadan hemen önce "çalışıyor mu?" kontrolü için.
    public let processes: any ProcessListing
    public var commandTimeout: Duration
    /// Taşıma işlemi. Gerçekte `FileManager.trashItem`; testte geçici klasöre taşıyan sahte verilir
    /// (gerçek Çöp Kutusu'na dokunulmasın diye).
    let mover: @Sendable (URL) throws -> URL?
    /// Cleaner'ın kendi çalıştırılabilir dosyası ve bundle id'si: kendi paketini taşımasın.
    let selfExecutable: URL?
    let selfBundleID: String?

    public init(policy: PathPolicy, commands: any CommandRunning, processes: any ProcessListing = LiveProcessLister(),
                commandTimeout: Duration = .seconds(600)) {
        self.init(policy: policy, commands: commands, processes: processes, commandTimeout: commandTimeout,
                  mover: Trasher.systemTrash)
    }

    init(policy: PathPolicy, commands: any CommandRunning, processes: any ProcessListing = LiveProcessLister(),
         commandTimeout: Duration = .seconds(600),
         selfExecutable: URL? = Bundle.main.executableURL, selfBundleID: String? = Bundle.main.bundleIdentifier,
         mover: @escaping @Sendable (URL) throws -> URL?) {
        self.policy = policy
        self.commands = commands
        self.processes = processes
        self.commandTimeout = commandTimeout
        self.selfExecutable = selfExecutable
        self.selfBundleID = selfBundleID
        self.mover = mover
    }

    static let systemTrash: @Sendable (URL) throws -> URL? = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

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
    func scanContextRejection(_ item: CleanItem, scanItems: [CleanItem]) -> String? {
        let mine = item.footprint.map { Trasher.key($0) }
        for other in scanItems where other.id != item.id && (other.isLocked || other.risk == .info) {
            for k in other.footprint.map({ Trasher.key($0) }) where mine.contains(where: { PathUtil.isSameOrDescendant(k, of: $0) }) {
                return "İçinde kullanımdaki ya da tutulacak öğe var: \(other.path)"
            }
        }
        return nil
    }

    static func key(_ path: String) -> String { PathUtil.key(PathUtil.canonical(URL(fileURLWithPath: path))) }

    /// Uygulama öğesi taşınamıyorsa nedeni.
    func appRejectionReason(for item: CleanItem) -> String? {
        appCheck(for: item).reason
    }

    /// Uygulama kontrolü; geçerse doğrulanmış bundle id'yi de döner (artıklar taşınırken yeniden kullanılır).
    func appCheck(for item: CleanItem) -> (reason: String?, bundleID: String?) {
        if let reason = policy.appBundleRejectionReason(for: item.url) { return (reason, nil) }
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

    /// Seçilen öğeleri taşır (dry-run'da yalnız raporlar).
    ///
    /// `scanItems`: aynı taramanın bütün öğeleri (CLI verir). Verilirse alt ağacında kilitli/bilgi öğesi olan
    /// öğe reddedilir ve mükerrer gruplarının tamamı bilinir.
    /// Aynı çalıştırmada hem üst hem alt öğe seçilirse alt öğe "üst öğeyle birlikte taşınıyor" diye atlanır
    /// (ret değildir, toplama girmez). Bir mükerrer grubunun hiç kopyası kalmayacaksa son kopya reddedilir.
    public func trash(_ items: [CleanItem], dryRun: Bool = true, scanItems: [CleanItem]? = nil) async -> TrashReport {
        var report = TrashReport(dryRun: dryRun, done: [], refused: [])
        var handled = Set<String>()
        var accepted: [CleanItem] = []
        for item in items {
            guard handled.insert(item.id).inserted else { continue }
            if let reason = rejectionReason(for: item) ?? scanItems.flatMap({ scanContextRejection(item, scanItems: $0) }) {
                report.refused.append(.init(id: item.id, path: item.path, reason: reason))
                continue
            }
            accepted.append(item)
        }
        accepted = applyGroupRule(accepted, scanItems: scanItems, report: &report)

        // Üst öğeler önce: alt öğe, üst öğesi bu çalıştırmada taşındıysa atlanır.
        let ordered = accepted.enumerated().sorted { a, b in
            let (da, db) = (Trasher.depth(a.element.path), Trasher.depth(b.element.path))
            return da != db ? da < db : a.offset < b.offset
        }.map(\.element)
        var coveredKeys: [(key: String, path: String)] = []
        for item in ordered {
            let isVirtual = item.path.hasPrefix("/docker/")
            if !isVirtual {
                let k = Trasher.key(item.path)
                if let parent = coveredKeys.first(where: { PathUtil.isSameOrDescendant(k, of: $0.key) }) {
                    report.skipped.append(.init(id: item.id, path: item.path, reason: "üst öğeyle birlikte taşınıyor: \(parent.path)"))
                    continue
                }
            }
            if await process(item, dryRun: dryRun, report: &report), !isVirtual {
                coveredKeys += item.footprint.map { (Trasher.key($0), item.path) }
            }
        }
        return report
    }

    static func depth(_ path: String) -> Int { path.split(separator: "/").count }

    /// Mükerrer grupları: taşıma sonunda grubun en az bir kopyası (diskte var olan, taşınmayan) kalmalı.
    /// Kalmayacaksa grubun seçilen son öğesi reddedilir.
    private func applyGroupRule(_ accepted: [CleanItem], scanItems: [CleanItem]?, report: inout TrashReport) -> [CleanItem] {
        var rejected = Set<String>()
        let groups = Set(accepted.compactMap(\.groupID))
        for g in groups.sorted() {
            let selected = accepted.filter { $0.groupID == g }
            // Grubun bilinen bütün kopyaları: anahtar -> gerçek yol.
            var members: [String: String] = [:]
            for i in (scanItems ?? []) where i.groupID == g { members[Trasher.key(i.path)] = i.path }
            for i in selected {
                members[Trasher.key(i.path)] = i.path
                if let k = i.keeperPath { members[Trasher.key(k)] = k }
            }
            let moving = Set(selected.map { Trasher.key($0.path) })
            let staying = members.filter { key, path in
                var st = stat()
                return !moving.contains(key) && lstat(path, &st) == 0
            }
            if staying.isEmpty, let last = selected.last {
                rejected.insert(last.id)
                report.refused.append(.init(id: last.id, path: last.path, reason: "mükerrer grubunun son kopyası; en az bir kopya kalmalı"))
            }
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
                    appendLeftovers(item, bundleID: id, dryRun: true, to: &report)
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
            do {
                let resulting = try mover(item.url)
                report.done.append(.init(id: item.id, path: item.path, bytes: item.allocatedBytes, action: .trashed, detail: resulting?.path))
            } catch {
                // Paket taşınamadıysa artıklarına dokunulmaz.
                report.refused.append(.init(id: item.id, path: item.path, reason: "taşınamadı: \(Trasher.describe(error))"))
                return false
            }
            if let verifiedBundleID {
                appendLeftovers(item, bundleID: verifiedBundleID, dryRun: false, to: &report)
            }
            return true
        }
    }

    /// Uygulama artıkları: ana paketten sonra, her biri ayrı ayrı son kontrolle. Boyutları ana öğenin
    /// boyutuna dahil olduğundan kendi satırları 0 bayttır. Bu arada silinmiş artık sessizce atlanır.
    /// `bundleID`: paket taşınmadan hemen önce Info.plist'ten doğrulanan kimlik.
    private func appendLeftovers(_ item: CleanItem, bundleID: String, dryRun: Bool, to report: inout TrashReport) {
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
                let resulting = try mover(url)
                report.done.append(.init(id: item.id, path: r, bytes: 0, action: .trashed, detail: resulting?.path))
            } catch {
                report.refused.append(.init(id: item.id, path: r, reason: "artık taşınamadı: \(Trasher.describe(error))"))
            }
        }
    }
}
