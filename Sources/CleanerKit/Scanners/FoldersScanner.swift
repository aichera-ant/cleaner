import Foundation

/// Proje köklerinde (derinlik 2) boş klasörleri ve yalnız `.DS_Store` içerenleri bulur.
/// Git depoları (içinde `.git` olan klasörler), korunan yollar, bulut kökleri ve paketler atlanır.
public struct FoldersScanner: Cleaner {
    public let id = "folders"
    public var categories: Set<Category> { [.folders] }
    /// Kökten itibaren en fazla bu kadar derine bakılır (kökün çocuğu = 1).
    public let maxDepth: Int

    public init(maxDepth: Int = 2) {
        self.maxDepth = maxDepth
    }

    public func scan(_ context: ScanContext) async throws -> [CleanItem] {
        let walker = FileWalker(cloudGuard: context.cloudGuard, skipDirNames: ["node_modules", ".git", ".Trash"])
        var items: [CleanItem] = []
        var seen = Set<String>()
        for root in context.roots {
            try context.checkCancellation()
            guard let rootInfo = walker.rootInfo(root), rootInfo.isDirectory else { continue }
            try await visit(rootInfo, depth: 0, rootDev: rootInfo.dev, walker: walker, context: context,
                            seen: &seen, items: &items)
        }
        return items
    }

    private func visit(_ dir: FSInfo, depth: Int, rootDev: dev_t, walker: FileWalker, context: ScanContext,
                       seen: inout Set<String>, items: inout [CleanItem]) async throws {
        try context.checkCancellation()
        // Listelenemeyen klasör (izin/G/Ç hatası) "boş" sayılmaz: atlanır.
        guard let names = FS.listing(dir.path) else { return }
        // Git kökü: içine hiç girilmez, aday olmaz.
        if names.contains(".git") { return }
        if depth > 0 {
            let onlyDSStore = names.allSatisfy { $0 == ".DS_Store" }
            if onlyDSStore, seen.insert(dir.path).inserted,
               context.pathPolicy.protectionReason(for: dir.url) == nil
            {
                let m = try await context.sizeMeter.measure(dir.url)
                items.append(CleanItem(
                    category: .folders,
                    name: dir.name,
                    path: dir.path,
                    allocatedBytes: m.allocatedBytes,
                    risk: .green,
                    dateSignal: context.signals.dateSignal(for: dir.url, now: context.now),
                    note: names.isEmpty ? "Boş klasör." : "Yalnız .DS_Store içeriyor.",
                    method: .trash
                ))
                return
            }
        }
        guard depth < maxDepth else { return }
        for child in try walker.children(of: dir, rootDev: rootDev) where child.isDirectory {
            try await visit(child, depth: depth + 1, rootDev: rootDev, walker: walker, context: context,
                            seen: &seen, items: &items)
        }
    }
}
