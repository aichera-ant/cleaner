import CleanerKit
import Foundation

/// Bir öğe silinirse ne olur: sade dilde "geri gelir mi" etiketi.
public enum Recovery: String, Sendable, Equatable, CaseIterable {
    /// Araç kendiliğinden yeniden oluşturur.
    case regenerates
    /// Gerektiğinde internetten yeniden indirilir ya da kurulur.
    case redownloads
    /// Geri gelmez ama Çöp Kutusu boşaltılana kadar geri alınabilir.
    case trashRestorable
    /// Komutla silinir; Çöp Kutusu'na gitmez, geri alınamaz.
    case permanent
    /// Bu uygulama temizleyemez (yalnız bilgi).
    case notRemovable

    public var label: String {
        switch self {
        case .regenerates: "Kendiliğinden yeniden oluşur"
        case .redownloads: "Gerekirse yeniden indirilir"
        case .trashRestorable: "Geri gelmez (Çöp Kutusu'ndan geri alınabilir)"
        case .permanent: "Kalıcı silinir, geri alınamaz"
        case .notRemovable: "Bu uygulama silmez"
        }
    }

    /// Rozet için kısa metin.
    public var shortLabel: String {
        switch self {
        case .regenerates: "Yeniden oluşur"
        case .redownloads: "Yeniden indirilir"
        case .trashRestorable: "Geri gelmez · Çöp Kutusu'nda"
        case .permanent: "Kalıcı silinir"
        case .notRemovable: "Silinmez"
        }
    }

    /// Silinince içerik kendiliğinden ya da internetten geri gelir mi?
    public var comesBack: Bool { self == .regenerates || self == .redownloads }
}

/// Bir öğenin teknik bilgisi olmayan biri için açıklaması.
public struct ItemExplanation: Sendable, Equatable {
    /// "Bu ne?" (tek cümle).
    public var what: String
    /// "Silersem ne olur?" (tek cümle).
    public var consequence: String
    public var recovery: Recovery
    /// Dikkat edilecek durumlar (kullanım, git, kilit...), sade dilde.
    public var heads: [String]
}

/// Öğe ve kategori açıklayıcısı. Saf işlev: ağ, disk ya da güvenlik mantığına dokunmaz; yalnız öğenin
/// kategorisi, adı, yolu, notu ve yöntemine bakar.
public enum ItemExplainer {
    public static func explain(_ item: CleanItem) -> ItemExplanation {
        var (what, cons, rec) = base(item)
        // Yöntem her şeyi belirler: komutla temizlenen kalıcı silinir, temizlenemeyen silinmez.
        switch item.method {
        case .command: rec = .permanent
        case .none: rec = item.category == .duplicates ? rec : .notRemovable
        case .trash: break
        }
        return ItemExplanation(what: what, consequence: cons, recovery: rec, heads: heads(item))
    }

    // MARK: Tür başına metinler

    private static func base(_ item: CleanItem) -> (String, String, Recovery) {
        switch item.category {
        case .xcode: return xcode(item)
        case .projectArtifacts: return projectArtifact(item)
        case .caches: return cache(item)
        case .docker: return docker(item)
        case .oldVersions: return oldVersion(item)
        case .largeOld: return largeOld(item)
        case .duplicates: return duplicate(item)
        case .folders:
            return ("Hiçbir şey içermeyen (ya da yalnız Finder'ın görünmez ayar dosyasını içeren) bir klasör.",
                    "Bir şey kaybolmaz; klasör Çöp Kutusu'na gider, istersen geri alırsın.", .trashRestorable)
        case .apps: return item.isLeftover ? leftover(item) : app(item)
        }
    }

    private static func xcode(_ item: CleanItem) -> (String, String, Recovery) {
        let n = item.name
        let p = item.path
        let isDerived = p.contains("/DerivedData/")
        let isWorktree = n.lowercased().contains("worktree")
        if isDerived && !isWorktree && n.hasPrefix("DerivedData") {
            return ("Xcode'un bir projeyi derlerken oluşturduğu geçici dosyalar.",
                    "Hiçbir şey kaybolmaz; projeyi yeniden açınca Xcode bunları baştan oluşturur, ilk derleme biraz uzun sürer.", .regenerates)
        }
        if isWorktree {
            return ("Xcode'un ayrı bir çalışma kopyası ya da otomatik araç için derlediği geçici dosyalar (teknik adı: worktree derlemesi).",
                    "Hiçbir şey kaybolmaz; o kopya yeniden derlenince bu dosyalar baştan oluşur, ilk derleme biraz uzun sürer.", .regenerates)
        }
        if n.hasPrefix("Xcode önbelleği:") {
            return ("Xcode'un derlemeyi hızlandırmak için sakladığı geçici dosyalar.",
                    "Hiçbir şey kaybolmaz; Xcode bunları gerektiğinde yeniden oluşturur.", .regenerates)
        }
        if n.hasPrefix("Arşiv") || p.contains("/Xcode/Archives/") {
            return ("Uygulamanı yayına hazırlarken Xcode'un sakladığı eski bir paket (teknik adı: xcarchive).",
                    "Yayınladığın uygulama etkilenmez, ama çökme raporlarını okunur kılan sembol dosyaları (dSYM) yalnız burada olabilir ve yeniden üretilemez.", .trashRestorable)
        }
        if n.contains("DeviceSupport") {
            return ("Xcode'un bağladığın telefon ya da saatten kopyaladığı sistem bilgileri.",
                    "Hiçbir şey kaybolmaz; cihazı Mac'e yeniden bağlayınca Xcode bunları tekrar kopyalar (biraz bekletir).", .regenerates)
        }
        if n.lowercased().contains("simülatör") || p.contains("/CoreSimulator/") {
            return ("Xcode'daki sanal bir iPhone/iPad; içinde denediğin uygulamalar ve onların verileri var.",
                    "Bu sanal cihaz ve içindeki uygulama verileri silinir; Xcode'dan istersen yeni bir tane oluşturabilirsin.", .regenerates)
        }
        return ("Xcode'un oluşturduğu geçici dosyalar.", "Xcode gerektiğinde bunları yeniden oluşturur.", .regenerates)
    }

    private static func projectArtifact(_ item: CleanItem) -> (String, String, Recovery) {
        let kind = (item.path as NSString).lastPathComponent
        let project = projectName(item.name)
        let proj = project.map { " (\($0) projesi)" } ?? ""
        switch kind {
        case "node_modules":
            return ("Projenin ihtiyaç duyduğu hazır kod paketlerinin indirilmiş kopyası\(proj) (teknik adı: node_modules).",
                    "Projenin kendi dosyaları kaybolmaz; projeyi tekrar çalıştırmadan önce paketleri yeniden indirmen gerekir (npm install), internet ister.", .redownloads)
        case ".next", ".turbo":
            return ("Web projesinin derlenirken oluşan geçici dosyaları\(proj) (teknik adı: \(kind)).",
                    "Hiçbir şey kaybolmaz; proje bir sonraki çalıştırmada bunları baştan oluşturur, ilk açılış biraz yavaş olur.", .regenerates)
        case "dist", "build":
            let untracked = (item.note ?? "").contains("git yok sayma kuralı yok")
            return ("Projenin derlenmiş, yayına hazır çıktısı\(proj) (teknik adı: \(kind)).",
                    untracked
                        ? "Proje kaynağından yeniden üretebiliyorsan sorun olmaz; üretemiyorsan bu klasör kaybolur, o yüzden önce bak."
                        : "Kaynak dosyaların etkilenmez; projeyi yeniden derleyince çıktı baştan oluşur.",
                    untracked ? .trashRestorable : .regenerates)
        default:
            if kind.hasPrefix(".next-") {
                return ("Web projesinin derlenirken oluşan geçici dosyaları\(proj) (teknik adı: \(kind)).",
                        "Hiçbir şey kaybolmaz; proje bir sonraki çalıştırmada bunları baştan oluşturur.", .regenerates)
            }
            return ("Projenin yeniden üretilebilen yardımcı dosyaları\(proj).",
                    "Kaynak dosyaların etkilenmez; araçlar bunları gerektiğinde yeniden oluşturur.", .regenerates)
        }
    }

    private static func projectName(_ name: String) -> String? {
        guard let open = name.firstIndex(of: "("), name.hasSuffix(")") else { return nil }
        return String(name[name.index(after: open)..<name.index(before: name.endIndex)])
    }

    private static func cache(_ item: CleanItem) -> (String, String, Recovery) {
        let p = item.path.lowercased()
        func has(_ s: String) -> Bool { p.contains(s) }
        if has("/.npm") { return ("npm'in (JavaScript paket aracı) daha önce indirdiği paketlerin saklı kopyaları.",
                                  "Hiçbir şey kaybolmaz; bir proje paket isteyince npm bunları yeniden indirir, o an biraz yavaşlar.", .redownloads) }
        if has("pnpm") { return ("pnpm'in (JavaScript paket aracı) indirdiği paketlerin saklı kopyaları.",
                                 "Hiçbir şey kaybolmaz; pnpm gerekli paketleri yeniden indirir. Hiçbir projenin kullanmadığı paketler silinir, kazanç gösterilenden az olabilir.", .redownloads) }
        if has("caches/google") { return ("Chrome'un sayfaları hızlı açmak için sakladığı geçici dosyalar.",
                                          "Hiçbir şey kaybolmaz (şifre ve yer imleri bunun içinde değil); siteler ilk açılışta biraz yavaş yüklenir.", .regenerates) }
        if has("ms-playwright") { return ("Web sitesi testleri için indirilmiş tarayıcılar (Playwright).",
                                          "Hiçbir şey kaybolmaz; testleri yeniden çalıştırınca bu tarayıcılar yeniden indirilir (büyük indirme).", .redownloads) }
        if has("colima") { return ("Colima'nın (Docker çalıştıran araç) indirdiği sanal makine dosyaları.",
                                   "Hiçbir şey kaybolmaz; Colima gerektiğinde bunları yeniden indirir.", .redownloads) }
        if has("swiftpm") { return ("Swift paketlerinin indirilmiş kopyaları (Swift Package Manager).",
                                    "Hiçbir şey kaybolmaz; Xcode ya da Swift bu paketleri bir sonraki derlemede yeniden indirir.", .redownloads) }
        if has("node-gyp") { return ("Bazı JavaScript paketlerinin derlenmesi için indirilen Node başlık dosyaları (node-gyp).",
                                     "Hiçbir şey kaybolmaz; gerektiğinde yeniden indirilir.", .redownloads) }
        if has("application support/claude/vm_bundles") { return ("Claude masaüstü uygulamasının kullandığı sanal makine paketi.",
                                                                  "Hiçbir şey kaybolmaz; uygulama gerek duyunca bunu yeniden indirir (büyük bir indirme).", .redownloads) }
        if has("application support/claude") { return ("Claude masaüstü uygulamasının sayfaları hızlı açmak için sakladığı geçici dosyalar.",
                                                       "Hiçbir şey kaybolmaz; uygulama bunları yeniden oluşturur.", .regenerates) }
        if has("homebrew") { return ("Homebrew'un (Mac için program kurma aracı) kurulum sırasında indirdiği dosyalar.",
                                     "Kurulu programlar etkilenmez; gerekirse bu dosyalar yeniden indirilir.", .redownloads) }
        if has("prisma") { return ("Prisma'nın (veritabanı aracı) indirdiği motor dosyaları.",
                                   "Hiçbir şey kaybolmaz; Prisma ilk kullanımda bunları yeniden indirir.", .redownloads) }
        if has("giget") { return ("Proje şablonu araçlarının indirdiği şablonların saklı kopyası (giget).",
                                  "Hiçbir şey kaybolmaz; şablon yeniden istenince indirilir.", .redownloads) }
        if has("yarn") { return ("Yarn'ın (JavaScript paket aracı) indirdiği paketlerin saklı kopyaları.",
                                 "Hiçbir şey kaybolmaz; Yarn gerekli paketleri yeniden indirir.", .redownloads) }
        if has(".bun") { return ("Bun'ın (JavaScript paket aracı) indirdiği paketlerin saklı kopyaları.",
                                 "Hiçbir şey kaybolmaz; Bun gerekli paketleri yeniden indirir.", .redownloads) }
        if has("caches/pip") { return ("pip'in (Python paket aracı) indirdiği paketlerin saklı kopyaları.",
                                       "Hiçbir şey kaybolmaz; pip gerekli paketleri yeniden indirir.", .redownloads) }
        if has("cocoapods") { return ("CocoaPods'un (iOS paket aracı) indirdiği kütüphanelerin saklı kopyaları.",
                                      "Hiçbir şey kaybolmaz; bir sonraki kurulumda yeniden indirilir.", .redownloads) }
        return ("Bir uygulamanın ya da aracın hızlanmak için sakladığı geçici dosyalar (önbellek).",
                "Kişisel dosyaların kaybolmaz; uygulama bunları gerektiğinde yeniden oluşturur ya da indirir.", .regenerates)
    }

    private static func docker(_ item: CleanItem) -> (String, String, Recovery) {
        let n = item.name
        if n.hasPrefix("Container:") {
            return ("Docker'da durmuş bir uygulama kutusu (container).",
                    "Kutu ve içine sonradan yazılmış dosyalar silinir; aynı imajdan yeni bir kutu oluşturabilirsin ama içindeki veriyi geri alamazsın.", .permanent)
        }
        if n.hasPrefix("İmaj:") {
            return ("Docker'ın bir uygulamayı çalıştırmak için indirdiği hazır paket (imaj).",
                    "Hiçbir kutu kullanmıyor; ihtiyaç olursa Docker bunu internetten yeniden indirir.", .redownloads)
        }
        if n.hasPrefix("Volume:") {
            return ("Docker kutularının veri sakladığı bir depolama alanı (volume); veritabanı gibi gerçek veri içerebilir.",
                    "İçindeki veriler silinir ve geri getirilemez. Ne olduğundan emin değilsen silme.", .permanent)
        }
        if n.hasPrefix("Docker build cache") {
            return ("Docker'ın imaj hazırlarken sakladığı ara dosyalar (derleme önbelleği).",
                    "Hiçbir şey kaybolmaz; bir sonraki imaj hazırlığı daha yavaş olur.", .regenerates)
        }
        if n.hasPrefix("colima disk") {
            return ("Colima'nın (Docker çalıştıran araç) sanal diski; büyük görünür ama diskte az yer tutar.",
                    "Bu uygulama bu dosyayı silmez; gösterilen boyut yalnız bilgi içindir.", .notRemovable)
        }
        if item.path.contains("com.docker.install") {
            return ("Docker Desktop kurulumundan kalan dosyalar.",
                    "Docker'ın çalışması için gerekmez; hiçbir şey kaybolmaz.", .regenerates)
        }
        return ("Docker'ın kullandığı bir kaynak.", "Silince Docker'daki ilgili kaynak kalkar.", .permanent)
    }

    private static func oldVersion(_ item: CleanItem) -> (String, String, Recovery) {
        let n = item.name
        if n.hasPrefix("Claude Code") {
            return ("Claude Code'un eski bir sürümü; güncelleme sırasında yedek olarak kalmış.",
                    "Güncel sürüm çalışmaya devam eder; eski sürüm lazım olursa yeniden indirilir.", .redownloads)
        }
        if n.hasPrefix("Eklenti") {
            return ("Kod editörünün (VS Code vb.) bir eklentisinin eski sürümü.",
                    "Editör yeni sürümü kullanmaya devam eder; eski sürüm kaybolur, gerekirse eklenti mağazasından yeniden gelir.", .redownloads)
        }
        if n.hasPrefix("Node") {
            return ("Mac'te kurulu, artık kullanılmayan eski bir Node.js sürümü (JavaScript çalıştıran program).",
                    "Bu sürümü isteyen bir proje olursa yeniden kurman gerekir (fnm/nvm ile kolayca kurulur).", .redownloads)
        }
        return ("Bir aracın eski sürümü.", "Yeni sürüm kalır; eskisi gerekirse yeniden kurulur.", .redownloads)
    }

    private static func largeOld(_ item: CleanItem) -> (String, String, Recovery) {
        let note = item.note ?? ""
        if note.contains("Kurulum/arşiv dosyası") {
            return ("İndirilenler'de duran büyük bir kurulum ya da arşiv dosyası.",
                    "Kurulumu yapılmış bir programa dokunmaz; dosya gerekirse yeniden indirilir (indirdiğin yer hâlâ duruyorsa).", .redownloads)
        }
        if note.contains("Seyrek dosya") {
            return ("Görünürde büyük ama diskte az yer kaplayan bir dosya (seyrek dosya).",
                    "Bu uygulama bu dosyayı silmez; silsen bile kazanç gösterilen boyuttan çok küçük olurdu.", .notRemovable)
        }
        if note.contains("klasör") {
            return ("Hiçbir kurala girmeyen büyük bir klasör; içinde kendi dosyaların olabilir.",
                    "İçindeki dosyalar kendiliğinden geri gelmez. Çöp Kutusu'nda durur, boşaltmazsan geri alabilirsin. Neyin olduğundan emin değilsen önce bak.", .trashRestorable)
        }
        return ("Hiçbir kurala girmeyen büyük bir dosya; senin kendi dosyan olabilir.",
                "Kendiliğinden geri gelmez. Çöp Kutusu'nda durur, boşaltmazsan geri alabilirsin. Neyin olduğundan emin değilsen önce bak.", .trashRestorable)
    }

    private static func duplicate(_ item: CleanItem) -> (String, String, Recovery) {
        if item.isDuplicateKeeper {
            return ("Aynı dosyanın birden fazla kopyası var; bu kopya tutulacak.",
                    "Bu kopyaya dokunulmaz.", .trashRestorable)
        }
        return ("Başka bir yerde birebir aynısı duran bir kopya.",
                "Dosyanın içeriği kaybolmaz çünkü diğer kopya durur; ama bu kopyanın bulunduğu yerde artık dosya olmaz. Çöp Kutusu'ndan geri alabilirsin.", .trashRestorable)
    }

    private static func app(_ item: CleanItem) -> (String, String, Recovery) {
        let hasLeft = (item.leftoverBytes ?? 0) > 0
        return ("Mac'inde kurulu bir uygulama\(hasLeft ? "; ayar ve veri artıkları ayrı satırlarda listelenir" : "").",
                "Uygulama kalkar. Gerekirse yeniden kurarsın; App Store ya da üreticinin sitesinden inebilir. Artıkları ayrıca işaretlemezsen yerinde kalır. Çöp Kutusu'ndan geri alabilirsin.",
                .trashRestorable)
    }

    /// Uygulama artığı: türü yoldan anlaşılır (Application Support, Caches, ...). Saf metin işlevi.
    private static func leftover(_ item: CleanItem) -> (String, String, Recovery) {
        let p = item.path
        let name = (p as NSString).lastPathComponent
        if p.contains("/Library/Application Support/") {
            return ("Uygulamanın ayarları ve verileri; uygulamayı silince işe yaramaz.",
                    "Uygulamayı yeniden kurarsan ayarların sıfırdan başlar. Uygulama kendi dosyalarını burada tutuyorsa onlar da gider. Çöp Kutusu'ndan geri alabilirsin.", .trashRestorable)
        }
        if p.contains("/Library/Caches/") {
            return ("Uygulamanın hızlanmak için sakladığı geçici dosyalar (önbellek).",
                    "Bir şey kaybolmaz; uygulama gerekirse yeniden oluşturur.", .regenerates)
        }
        if p.contains("/Library/Preferences/") {
            return ("Uygulamanın ayar dosyası.",
                    "Uygulamayı yeniden kurarsan ayarların sıfırdan başlar.", .trashRestorable)
        }
        if p.contains("/Library/Logs/") {
            return ("Uygulamanın tuttuğu kayıt (log) dosyaları.",
                    "Zararsız; yalnız eski kayıtlar gider.", .regenerates)
        }
        if p.contains("/Library/Group Containers/") {
            return ("Aynı geliştiricinin uygulamalarının ortak kullandığı veri alanı.",
                    "Aynı geliştiricinin başka bir uygulaması kuruluysa onun verileri de gidebilir. Çöp Kutusu'ndan geri alabilirsin.", .trashRestorable)
        }
        if p.contains("/Library/Containers/") {
            return ("Uygulamanın macOS'un ayırdığı kendi kutusu; ayarları ve verileri burada durur.",
                    "Uygulamanın ayarları ve verileri gider; yeniden kurarsan sıfırdan başlar. Çöp Kutusu'ndan geri alabilirsin.", .trashRestorable)
        }
        if p.contains("/Library/Saved Application State/") {
            return ("Uygulamanın pencerelerini nerede bıraktığını hatırladığı kayıt.",
                    "Zararsız; uygulama pencereleri varsayılan yerde açar.", .regenerates)
        }
        if p.contains("/Library/HTTPStorages/") {
            return ("Uygulamanın internet bağlantılarında sakladığı oturum kayıtları.",
                    "Uygulamayı yeniden kurarsan internet hesaplarında yeniden oturum açman gerekebilir.", .regenerates)
        }
        if p.contains("/Library/WebKit/") {
            return ("Uygulamanın içindeki web görünümlerinin sakladığı çerez ve geçici veriler.",
                    "Uygulamayı yeniden kurarsan internet hesaplarında yeniden oturum açman gerekebilir.", .regenerates)
        }
        if name.hasPrefix(".") {
            return ("Uygulamanın ev klasöründe bıraktığı gizli ayar ve veri klasörü (\(name)).",
                    "Uygulamayı yeniden kurarsan ayarların sıfırdan başlar. Çöp Kutusu'ndan geri alabilirsin.", .trashRestorable)
        }
        return ("Uygulamanın geride bıraktığı ayar ya da veri dosyası.",
                "Uygulamayı yeniden kurarsan ayarların sıfırdan başlar. Çöp Kutusu'ndan geri alabilirsin.", .trashRestorable)
    }

    // MARK: Dikkat notları

    private static func heads(_ item: CleanItem) -> [String] {
        var out: [String] = []
        let note = item.note ?? ""
        if let lock = item.lockReason, !lock.isEmpty {
            out.append("Şu an kullanımda ya da korumalı, bu yüzden seçilemez: \(lock).")
        }
        if item.category == .projectArtifacts, item.preselect == false, let d = item.dateSignal.days {
            out.append("Son \(max(d, 1)) günde kullanıldı — çalıştığın bir projeye ait olabilir.")
        } else if note.contains("Son 1 günde kullanıldı") {
            out.append("Son 1 günde kullanıldı — şu an çalıştığın bir projeye ait olabilir.")
        }
        if note.contains("commit edilmemiş değişiklik") {
            out.append("Bu projede kaydedilmemiş (commit edilmemiş) değişiklik var; kaynak dosyalara dokunulmaz ama dikkatli ol.")
        }
        if note.contains("push edilmemiş commit") {
            out.append("Bu projede sunucuya gönderilmemiş (push edilmemiş) değişiklik var; kaynak dosyalara dokunulmaz.")
        }
        if item.needsAuthorization == true {
            out.append("macOS silmeden önce parola ya da Touch ID isteyecek.")
        }
        if item.leftoverMatch == .name {
            out.append("Adı benziyor, başka uygulamaya ait olabilir; emin değilsen seçme.")
        }
        if item.category == .apps, !item.isLeftover, item.risk == .info {
            out.append("Yakında açılmış; kullanıyor olabilirsin.")
        }
        if item.category == .largeOld, item.risk == .red {
            out.append("Bunu sen karar vermelisin; uygulama içeriği bilemez.")
        }
        return out
    }

    // MARK: Özet ve kategori

    /// Onay sayfasının üstündeki tek cümle.
    public static func summary(_ items: [CleanItem]) -> String {
        guard !items.isEmpty else { return "Seçili öğe yok." }
        let recs = items.map { explain($0).recovery }
        let permanent = recs.filter { $0 == .permanent }.count
        let gone = recs.filter { $0 == .trashRestorable || $0 == .permanent }.count
        if gone == 0 {
            return recs.allSatisfy { $0 == .regenerates }
                ? "Bunların hepsi kendiliğinden yeniden oluşur."
                : "Bunların hepsi gerekirse yeniden oluşur ya da indirilir; bir şey kaybetmezsin."
        }
        if permanent > 0 {
            return "\(items.count) öğenin \(gone) tanesi geri gelmez; bunların \(permanent) tanesi kalıcı silinir (Çöp Kutusu'ndan geri alınamaz)."
        }
        return "\(items.count) öğenin \(gone) tanesi kendiliğinden geri gelmez; ama hepsi Çöp Kutusu'nda durur, boşaltana kadar geri alabilirsin."
    }

    /// Kategoriyi sade dille anlatan kısa metin (kategori sayfası başı ve onay sayfası başlık altı).
    public static func categoryIntro(_ c: ItemCategory) -> String {
        switch c {
        case .xcode: "Xcode'un (iPhone/Mac uygulaması yazma programı) derleme sırasında biriktirdiği geçici dosyalar ve sanal telefonlar. Çoğu silinse bile Xcode baştan oluşturur."
        case .projectArtifacts: "Yazılım projelerinin içinde biriken, araçların yeniden üretebildiği klasörler (indirilmiş paketler, derleme çıktıları). Projenin kendi dosyalarına dokunulmaz."
        case .caches: "Programların hızlanmak için sakladığı geçici kopyalar (önbellek). Kişisel dosyaların değildir; silinince program gerektiğinde yeniden oluşturur ya da indirir."
        case .docker: "Docker'ın (programları izole kutularda çalıştıran araç) biriktirdiği kutular, paketler ve depolar. Bazıları veri içerebilir, o yüzden tek tek bak."
        case .oldVersions: "Aynı programın birden fazla sürümü kurulu. En yenisi kalır, eskileri silmek yer açar; gerekirse yeniden kurulur."
        case .largeOld: "Diskte çok yer kaplayan büyük dosyalar ve klasörler. Çoğu senin kendi dosyan olabilir ve silinince kendiliğinden geri gelmez, bu yüzden kararı sen verirsin."
        case .duplicates: "İçeriği birebir aynı olan dosyalar. Her grupta bir kopya kalır, diğerleri silinebilir. Silinen kopya kendiliğinden geri gelmez."
        case .folders: "İçinde hiçbir şey olmayan klasörler. Silmek bir şey kaybettirmez."
        case .apps: "Uzun süredir açmadığın uygulamalar ve geride bıraktıkları dosyalar. Silersen uygulama ve ayarları kalkar; gerekirse yeniden kurarsın."
        }
    }
}
