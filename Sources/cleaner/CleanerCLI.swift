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

    @Option(name: .long, parsing: .upToNextOption, help: "Proje kökleri (varsayılan: ~/Documents/projeler ~/Desktop).")
    var roots: [String] = []

    func makeContext() throws -> ScanContext {
        // İkinci savunma hattı: bu süreçte dataless dosya okunarak indirilemez.
        CloudGuard.disableDatalessMaterializationForProcess()
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
        let report = try await ScanEngine().scan(context, categories: options.categoryFilter)
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
        // id'ler yeniden taramayla çözülür; kilit durumu taşıma anında güncel olur.
        let report = try await ScanEngine().scan(context, categories: options.categoryFilter)
        let byID = Dictionary(report.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var selected: [CleanItem] = []
        var unknown: [String] = []
        for id in ids {
            if let item = byID[id] { selected.append(item) } else { unknown.append(id) }
        }
        let trasher = Trasher(policy: context.pathPolicy, commands: context.signals.commands)
        var result = await trasher.trash(selected, dryRun: dryRun)
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

    static func printScan(_ report: ScanReport) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for (category, total) in report.totalsByCategory() {
            print("\n== \(category.rawValue)  \(bytes(total))")
            for item in report.items where item.category == category {
                let sel = item.isDefaultSelected ? "*" : " "
                let path = item.path.hasPrefix(home) ? "~" + item.path.dropFirst(home.count) : item.path
                var line = "\(sel) \(item.id)  \(lpad(bytes(item.allocatedBytes), 9))  \(pad(risk(item.risk), 8)) \(pad(date(item.dateSignal), 14)) \(pad(item.name, 32)) \(path)"
                if case .command(let c) = item.method { line += "  [komut: \(c)]" }
                if let lock = item.lockReason { line += "  (\(lock))" }
                print(line)
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
        for x in r.refused { print("Reddedildi: \(x.id) \(x.path)  neden: \(x.reason)") }
        print("Toplam \(r.dryRun ? "taşınacak" : "kazanılan"): \(bytes(r.totalBytes))")
        if r.dryRun { print("Gerçekten taşımak için --no-dry-run ekleyin.") }
    }
}
