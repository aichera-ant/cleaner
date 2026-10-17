#if DEBUG
import CleanerAppCore
import CleanerKit
import Foundation

/// PNG çizimi için sahte veri. Gerçek dosya sistemine dokunmaz.
enum SampleData {
    static let home = NSHomeDirectory()
    static let MB: UInt64 = 1_000_000
    static let GB: UInt64 = 1_000_000_000

    static func items() -> [CleanItem] {
        let h = home
        var out: [CleanItem] = [
            CleanItem(category: .xcode, name: "DerivedData · ornekproje-ios", path: "\(h)/Library/Developer/Xcode/DerivedData/ornekproje-ios-abc", allocatedBytes: 6 * GB + 400 * MB, risk: .green, dateSignal: .modified(days: 41), note: "Her derlemede yeniden oluşur."),
            CleanItem(category: .xcode, name: "DerivedData · hepp-1d3 (worktree)", path: "\(h)/Library/Developer/Xcode/DerivedData/hepp-1d3-xyz", allocatedBytes: 3 * GB + 100 * MB, risk: .green, dateSignal: .modified(days: 12)),
            CleanItem(category: .xcode, name: "iOS 17.2 simülatörü", path: "\(h)/Library/Developer/CoreSimulator/Devices/A1", allocatedBytes: 2 * GB, risk: .yellow, dateSignal: .opened(days: 150), note: "Kullanılmayan (unavailable) simülatör."),
            CleanItem(category: .xcode, name: "iPhone 15 Pro (açık)", path: "\(h)/Library/Developer/CoreSimulator/Devices/B2", allocatedBytes: 1 * GB, risk: .locked, dateSignal: .opened(days: 0), lockReason: "Simülatör açık"),
            CleanItem(category: .projectArtifacts, name: "ornekproje/node_modules", path: "\(h)/Documents/projeler/ornekproje/node_modules", allocatedBytes: 1 * GB + 480 * MB, risk: .green, dateSignal: .modified(days: 94)),
            CleanItem(category: .projectArtifacts, name: "cleaner-web/.next", path: "\(h)/Documents/projeler/cleaner-web/.next", allocatedBytes: 612 * MB, risk: .green, dateSignal: .modified(days: 8), preselect: false),
            CleanItem(category: .projectArtifacts, name: "api/node_modules", path: "\(h)/Documents/projeler/api/node_modules", allocatedBytes: 402 * MB, risk: .green, dateSignal: .modified(days: 0), lockReason: "Bugün değişti, kullanımda olabilir"),
            CleanItem(category: .caches, name: "npm önbelleği", path: "\(h)/.npm", allocatedBytes: 2300 * MB, risk: .green, method: .command("npm cache clean --force")),
            CleanItem(category: .caches, name: "pnpm deposu", path: "\(h)/Library/pnpm", allocatedBytes: 1200 * MB, risk: .green, note: "Yalnız hiçbir projenin kullanmadığı paketler gider.", method: .command("pnpm store prune")),
            CleanItem(category: .caches, name: "Playwright tarayıcıları", path: "\(h)/Library/Caches/ms-playwright", allocatedBytes: 572 * MB, risk: .yellow, note: "E2E testleri ilk çalıştırmada yeniden indirir."),
            CleanItem(category: .caches, name: "Homebrew önbelleği", path: "\(h)/Library/Caches/Homebrew", allocatedBytes: 340 * MB, risk: .green, dateSignal: .modified(days: 120)),
            CleanItem(category: .docker, name: "Kullanılmayan image'lar", path: "/docker/images/unused", allocatedBytes: 4 * GB, risk: .yellow, method: .command("docker image prune")),
            CleanItem(category: .docker, name: "postgres:16 (çalışan container)", path: "/docker/containers/pg", allocatedBytes: 800 * MB, risk: .locked, lockReason: "Container çalışıyor"),
            CleanItem(category: .oldVersions, name: "Claude Code 2.1.288", path: "\(h)/.local/share/claude/versions/2.1.288", allocatedBytes: 236 * MB, risk: .green, dateSignal: .opened(days: 40)),
            CleanItem(category: .oldVersions, name: "Claude Code 2.1.301", path: "\(h)/.local/share/claude/versions/2.1.301", allocatedBytes: 239 * MB, risk: .locked, dateSignal: .opened(days: 0), lockReason: "Kullanılan sürüm"),
            CleanItem(category: .largeOld, name: "montaj-ham.mov", path: "\(h)/Movies/montaj-ham.mov", allocatedBytes: 3 * GB, risk: .red, dateSignal: .modified(days: 400), note: "Kural listesinde yok; karar senin."),
            CleanItem(category: .largeOld, name: "Eski-yedek.dmg", path: "\(h)/Downloads/Eski-yedek.dmg", allocatedBytes: 1 * GB + 200 * MB, risk: .red, dateSignal: .modified(days: 700)),
            CleanItem(category: .folders, name: "bos-proje", path: "\(h)/Desktop/bos-proje", allocatedBytes: 0, risk: .green, dateSignal: .modified(days: 200), note: "Boş klasör."),
        ]
        func dup(_ g: String, _ name: String, _ size: UInt64, paths: [(String, Risk, String?)], keeper: String) {
            for (p, r, lock) in paths {
                out.append(CleanItem(category: .duplicates, name: name, path: p, allocatedBytes: size, risk: r, dateSignal: .modified(days: 60),
                                     lockReason: lock, note: r == .info ? nil : "Aynısı duruyor: \(keeper)", groupID: g, keeperPath: keeper))
            }
        }
        dup("g1", "sunum-final.pdf", 180 * MB, paths: [
            ("\(h)/Documents/sunum-final.pdf", .info, nil),
            ("\(h)/Downloads/sunum-final.pdf", .green, nil),
            ("\(h)/Desktop/sunum-final (1).pdf", .green, nil),
        ], keeper: "\(h)/Documents/sunum-final.pdf")
        dup("g2", "logo-kaynak.psd", 64 * MB, paths: [
            ("\(h)/Documents/logo-kaynak.psd", .info, nil),
            ("\(h)/Downloads/logo-kaynak.psd", .yellow, nil),
        ], keeper: "\(h)/Documents/logo-kaynak.psd")
        func app(_ n: String, _ size: UInt64, _ days: Int, risk: Risk = .yellow, lock: String? = nil, related: Int = 0) {
            out.append(CleanItem(category: .apps, name: n, path: "/Applications/\(n).app", allocatedBytes: size, risk: risk,
                                 dateSignal: .opened(days: days), lockReason: lock,
                                 relatedPaths: (0..<related).map { "\(h)/Library/Application Support/\(n)/\($0)" }))
        }
        app("Pixelmator Pro", 1500 * MB, 410, related: 3)
        app("Sketch", 700 * MB, 250, related: 2)
        app("Visual Studio Code", 1480 * MB, 0, risk: .locked, lock: "Kayıt yok ama code komutuyla kullanılıyor")
        app("Notion Calendar", 320 * MB, 190)
        return out
    }
}

struct SampleScanService: ScanService {
    var neverFinish = false
    var progressUpTo: Int = 0

    func scan(progress: (@Sendable (AppScanProgress) -> Void)?) async throws -> ScanSnapshot {
        if neverFinish {
            let cats = CategoryInfo.all.map(\.category)
            for (i, c) in cats.enumerated() where i <= progressUpTo + 1 {
                progress?(.init(scanner: c.rawValue, categories: [c], event: .started, completed: i, total: cats.count))
                if i < progressUpTo + 1 {
                    progress?(.init(scanner: c.rawValue, categories: [c], event: .finished(itemCount: 3, bytes: UInt64(i + 1) * SampleData.GB), completed: i + 1, total: cats.count))
                }
            }
            try await Task.sleep(for: .seconds(120))
        }
        return ScanSnapshot(items: SampleData.items(), scannedAt: Date())
    }
}

/// Gerçek taşıma yapmaz: kabul edilenleri "yapıldı" sayar, ilk sarı öğeyi reddeder.
struct SampleTrashService: TrashService {
    func trash(ids: [String], scan: [CleanItem], keepers: [String: String], dryRun: Bool) async -> TrashReport {
        let picked = ids.compactMap { id in scan.first { $0.id == id } }
        var done: [TrashReport.Done] = []
        var refused: [TrashReport.Refused] = []
        for i in picked {
            if i.risk == .yellow && refused.isEmpty {
                refused.append(.init(id: i.id, path: i.path, reason: "izin yok (yönetici izni gerekir): Bu işlem için izniniz yok."))
                continue
            }
            var action = "trashed"
            var detail: String?
            if case .command(let c) = i.method { action = "command"; detail = c }
            var obj: [String: Any] = ["id": i.id, "path": i.path, "bytes": i.allocatedBytes, "action": action]
            if let detail { obj["detail"] = detail }
            if let data = try? JSONSerialization.data(withJSONObject: obj),
               let d = try? JSONDecoder().decode(TrashReport.Done.self, from: data) { done.append(d) }
        }
        let skipped = [TrashReport.Refused(id: "x", path: "\(SampleData.home)/Documents/projeler/ornekproje/node_modules/.cache",
                                           reason: "üst öğeyle birlikte taşınıyor: ~/Documents/projeler/ornekproje/node_modules")]
        return TrashReport(dryRun: dryRun, done: done, refused: refused, skipped: skipped)
    }
}
#endif
