import ArgumentParser
import CleanerKit
import Foundation

@main
struct CleanerCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleaner",
        abstract: "macOS disk temizleme: tarama ve Çöp Kutusu'na taşıma.",
        subcommands: [Scan.self, Trash.self]
    )
}

struct ScanOptions: ParsableArguments {
    @Option(name: .long, help: "Yalnız bu kategoriler (\(CleanerKit.Category.allCases.map(\.rawValue).joined(separator: ", "))).")
    var category: [CleanerKit.Category] = []

    @Option(name: .long, parsing: .upToNextOption, help: "Taranacak kökler; verilirse bütün tarayıcılar bunu kullanır (varsayılan: tarayıcıya göre; proje/klasör ~/Documents/projeler ~/Desktop, mükerrer ana klasör).")
    var roots: [String] = []

    func makeContext() throws -> ScanContext {
        // İkinci savunma hattı: bu süreçte dataless dosya okunarak indirilemez.
        CloudGuard.disableDatalessMaterializationForProcess()
        // Kök verilmezse her tarayıcı kendi varsayılanını kullanır (proje/klasör: projeler + Desktop,
        // mükerrer: ana klasör). Verilirse hepsi verileni kullanır.
        let rootURLs = roots.isEmpty ? nil : roots.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL
        }
        return try ScanContext.live(roots: rootURLs)
    }

    var categoryFilter: Set<CleanerKit.Category>? { category.isEmpty ? nil : Set(category) }
}

extension CleanerKit.Category: ExpressibleByArgument {}

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Temizlenebilir öğeleri listeler (hiçbir şeye dokunmaz).")

    @OptionGroup var options: ScanOptions

    @Flag(name: .long, help: "JSON çıktı.")
    var json = false

    func run() async throws {
        let context = try options.makeContext()
        // `--category` ile yalnız ilgili tarayıcılar çalışır (hızlı görüntüleme). Kilit ve çift sayım hesabı
        // tam taramada kesinleşir; `trash` her zaman tam tarar.
        let report = try await ScanEngine().scan(context, categories: options.categoryFilter,
                                                 fullLockCheck: options.categoryFilter == nil)
        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try enc.encode(report), as: UTF8.self))
        } else {
            Output.printScan(report)
        }
    }
}

struct Trash: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Öğeleri Çöp Kutusu'na taşır. Varsayılan dry-run; gerçekten taşımak için --no-dry-run."
    )

    @Argument(help: "scan çıktısındaki id'ler.")
    var ids: [String]

    @Flag(inversion: .prefixedNo, help: "Yalnız ne yapılacağını göster (varsayılan).")
    var dryRun = true

    @OptionGroup var options: ScanOptions

    @Flag(name: .long, help: "JSON çıktı.")
    var json = false

    func run() async throws {
        let context = try options.makeContext()
        // id'ler yeniden ve TAM taramayla çözülür (bütün tarayıcılar): kilit durumu, iç içe öğeler ve mükerrer
        // grupları taşıma anında güncel olur. `--category` yalnız id çözümünü daraltır.
        let report = try await ScanEngine().scan(context)
        let filter = options.categoryFilter
        // Kategori süzgecine uymayan id'ler bulunamamış sayılır; geri kalanı Trasher tarama sonucundan çözer.
        var selected: [String] = []
        var unknown: [String] = []
        for id in ids {
            if let filter, let item = report.items.first(where: { $0.id == id }), !filter.contains(item.category) {
                unknown.append(id)
            } else {
                selected.append(id)
            }
        }
        let trasher = Trasher(policy: context.pathPolicy, commands: context.signals.commands)
        var result = await trasher.trash(ids: selected, scan: report.items, dryRun: dryRun)
        result.refused += unknown.map { TrashReport.Refused(id: $0, path: "", reason: "bu taramada bulunamadı") }
        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try enc.encode(result), as: UTF8.self))
        } else {
            Output.printTrash(result)
        }
        if !result.refused.isEmpty { throw ExitCode(2) }
    }
}

enum Output {
    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .file)
    }

    static func date(_ d: DateSignal) -> String {
        switch d {
        case .opened(let n): "açıldı \(n) g"
        case .modified(let n): "değişti \(n) g"
        case .unknown: "bilinmiyor"
        }
    }

    static func risk(_ r: Risk) -> String {
        switch r {
        case .green: "yeşil"
        case .yellow: "sarı"
        case .red: "kırmızı"
        case .locked: "kilitli"
        case .info: "bilgi"
        }
    }

    static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }

    static func lpad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
    }

    static func tilde(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Tek satıra indirilmiş, kısaltılmış metin.
    static func oneLine(_ s: String, max: Int = 110) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    /// Öğenin alt satırları: kilit nedeni, mükerrer grubu, not.
    static func details(_ item: CleanItem, home: String) -> [String] {
        var out: [String] = []
        if let lock = item.lockReason { out.append("kilit: " + oneLine(lock)) }
        if item.needsAuthorization == true {
            out.append("yetki gerekir: macOS parola ya da Touch ID; CLI taşımaz, Hepp Cleaner uygulamasından kaldırın")
        }
        if let g = item.groupID {
            let keeper = item.keeperPath.map { tilde($0, home: home) } ?? "?"
            out.append(item.isDuplicateKeeper ? "grup \(g) · tutulacak kopya bu" : "grup \(g) · tutulacak: " + oneLine(keeper))
        }
        if let lb = item.leftoverBytes { out.append("kesin artıklar: \(bytes(lb)) (ayrı öğeler, aşağıda)") }
        if let note = item.note, !note.isEmpty { out.append("not: " + oneLine(note)) }
        return out
    }

    static func printScan(_ report: ScanReport) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for (category, total) in report.totalsByCategory() {
            print("\n== \(category.rawValue)  \(bytes(total))")
            let inCategory = report.items.filter { $0.category == category }
            // Uygulama artıkları uygulamalarının altında (girintili); uygulaması listede olmayanlar sonda.
            let parentIDs = Set(inCategory.filter { !$0.isLeftover }.map(\.id))
            var children: [String: [CleanItem]] = [:]
            for i in inCategory where i.isLeftover { children[i.parentAppID ?? "", default: []].append(i) }
            func emit(_ item: CleanItem, indent: String) {
                let sel = item.isDefaultSelected ? "*" : " "
                let path = tilde(item.path, home: home)
                var line = "\(indent)\(sel) \(item.id)  \(lpad(bytes(item.allocatedBytes), 9))  \(pad(risk(item.risk), 8)) \(pad(date(item.dateSignal), 14)) \(pad(item.name, 32)) \(path)"
                if case .command(let c) = item.method { line += "  [komut: \(c)]" }
                if let m = item.leftoverMatch { line += m == .bundleID ? "  [artık: kesin]" : "  [artık: ad benzerliği]" }
                print(line)
                for detail in details(item, home: home) { print("\(indent)      \(detail)") }
            }
            for item in inCategory where !item.isLeftover {
                emit(item, indent: "")
                for c in children[item.id] ?? [] { emit(c, indent: "    └ ") }
            }
            for item in inCategory where item.isLeftover && !parentIDs.contains(item.parentAppID ?? "") {
                emit(item, indent: "")
            }
        }
        let total = report.items.reduce(UInt64(0)) { $0 &+ $1.allocatedBytes }
        let selected = report.items.filter(\.isDefaultSelected).reduce(UInt64(0)) { $0 &+ $1.allocatedBytes }
        print("\nToplam: \(bytes(total)) (\(report.items.count) öğe), varsayılan seçili (*): \(bytes(selected))")
        for e in report.errors { print("! \(e.scanner): \(e.message)") }
        if !report.dropped.isEmpty { print("Korunan yol olduğu için atlanan: \(report.dropped.count)") }
    }

    static func printTrash(_ r: TrashReport) {
        let verb = r.dryRun ? "(dry-run) " : ""
        for d in r.done {
            switch d.action {
            case .trashed: print("\(verb)Çöp Kutusu'na: \(d.path)  \(bytes(d.bytes))")
            case .command: print("\(verb)Komut: \(d.detail ?? "")  (\(d.path), \(bytes(d.bytes)))")
            }
        }
        for x in r.skipped { print("\(verb)Atlandı: \(x.id) \(x.path)  (\(x.reason))") }
        for x in r.refused { print("Reddedildi: \(x.id) \(x.path)  neden: \(x.reason)") }
        print("Toplam \(r.dryRun ? "taşınacak" : "kazanılan"): \(bytes(r.totalBytes))")
        if r.dryRun { print("Gerçekten taşımak için --no-dry-run ekleyin.") }
    }
}
