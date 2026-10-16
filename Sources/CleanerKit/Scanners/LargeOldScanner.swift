import Foundation

/// Ana klasörde büyük dosyaları ve büyük klasör adaylarını bulur.
///
/// - Adaylar kural dışıdır: kırmızı, seçili değil (karar kullanıcıda). `~/Downloads` içindeki
///   `.dmg/.pkg/.zip` kurulum dosyaları sarıdır (yeniden indirilir).
/// - `~/Library` gezilmez (diğer tarayıcıların alanı); yalnız `~/Library/Application Support` gezilir.
/// - Kurallarla (`rules.json`) ve diğer tarayıcıların öğeleriyle (`context.claimedPaths`) örtüşen yollar
///   atlanır; onları kapsayan klasör aday olmaz, içindeki geri kalan büyük dosyalar ayrı öğe olur.
/// - Listelenemeyen klasör atlanır; onu kapsayan klasör aday olmaz.
/// - Seyrek dosya (görünen boyut büyük, ayrılan küçük) bilgi satırıdır, taşınamaz.
/// - Boyut ön süzgeci `lstat` boyutudur; öğelerin ayrılan boyutu `SizeMeter` ile ölçülür.
public struct LargeOldScanner: Cleaner {
    public let id = "largeOld"
    public var categories: Set<Category> { [.largeOld] }
    /// İkinci aşama: diğer tarayıcıların öğeleri (`context.claimedPaths`) bilinerek çalışır; o yolları
    /// saymaz ve onları kapsayan klasörü aday yapmaz (içindeki geri kalan büyük dosyalar ayrı öğe olur).
    public var phase: Int { 1 }

    /// Büyük dosya eşiği (bayt).
    public let minFileBytes: UInt64
    /// Bir klasörün içindeki büyük dosyaların toplamı bu eşiği aşarsa klasör adayı olabilir.
    public let folderCandidateBytes: UInt64

    public init(minFileBytes: UInt64 = 50 * 1_048_576, folderCandidateBytes: UInt64 = 500 * 1_048_576) {
        self.minFileBytes = minFileBytes
        self.folderCandidateBytes = folderCandidateBytes
    }

    static let skipDirNames: Set<String> = [
        "node_modules", ".git", ".build", ".next", ".next-e2e", ".turbo", "DerivedData", "CoreSimulator", ".Trash",
    ]
    static let installerExtensions: Set<String> = ["dmg", "pkg", "zip"]

    // MARK: - Ağaç

    private struct BigFile: Sendable {
        var info: FSInfo
    }

    private final class DirNode: @unchecked Sendable {
        let info: FSInfo
        var files: [BigFile] = []
        var children: [DirNode] = []
        var mass: UInt64 = 0
        var isGitRoot = false
        /// Alt ağaçta başka tarayıcının öğesi ya da listelenemeyen klasör var: klasör adayı olamaz.
        var notCandidate = false
        init(info: FSInfo) { self.info = info }
    }

    public func scan(_ context: ScanContext) async throws -> [CleanItem] {
        let home = context.home.standardizedFileURL
        let covered = Self.ruleCoveredPaths(context)
        let walker = FileWalker(
            cloudGuard: context.cloudGuard,
            skipDirNames: Self.skipDirNames,
            skipPaths: covered
        )
        guard let homeInfo = walker.rootInfo(home), homeInfo.isDirectory else { return [] }
        let rootDev = homeInfo.dev
        let minBytes = Int64(minFileBytes)

        // Üst düzey adaylar: ana klasörün çocukları (Library hariç) ve Application Support çocukları.
        let appSupport = FS.join(homeInfo.path, "Library/Application Support")
        var topDirs: [FSInfo] = []
        var homeFiles: [FSInfo] = []
        for child in try walker.children(of: homeInfo, rootDev: rootDev) {
            if child.name == "Library" { continue }
            if child.isDirectory { topDirs.append(child) } else if child.size >= minBytes { homeFiles.append(child) }
        }
        if let asInfo = FS.info(appSupport), asInfo.isDirectory, !covered.contains(appSupport) {
            for child in try walker.children(of: asInfo, rootDev: rootDev) {
                if child.isDirectory { topDirs.append(child) } else if child.size >= minBytes { homeFiles.append(child) }
            }
        }

        let claimed = context.claimedPaths
        topDirs.removeAll { claimed.contains(PathUtil.key($0.path)) }
        homeFiles.removeAll { claimed.contains(PathUtil.key($0.path)) }
        let nodes = try await boundedParallelMap(topDirs, width: 8) { dir in
            try Self.build(dir, walker: walker, rootDev: rootDev, minBytes: minBytes, claimed: claimed)
        }

        var items: [CleanItem] = []
        for f in homeFiles {
            try context.checkCancellation()
            if let item = try await fileItem(f, context: context) { items.append(item) }
        }
        for node in nodes.compactMap({ $0 }) {
            try await emit(node, context: context, items: &items)
        }
        return items
    }

    // MARK: - Ağaç kurma (yalnız meta veri)

    private static func build(_ dir: FSInfo, walker: FileWalker, rootDev: dev_t, minBytes: Int64,
                              claimed: Set<String>) throws -> DirNode? {
        let node = DirNode(info: dir)
        guard let children = try walker.listChildren(of: dir, rootDev: rootDev) else {
            // Listelenemedi: içi bilinmiyor, atlanır; kapsayan klasör de aday olamaz.
            node.notCandidate = true
            return node
        }
        for child in children {
            if !claimed.isEmpty, claimed.contains(PathUtil.key(child.path)) {
                node.notCandidate = true // başka tarayıcının öğesi: sayılmaz, içine inilmez
                continue
            }
            if child.isDirectory {
                if let sub = try build(child, walker: walker, rootDev: rootDev, minBytes: minBytes, claimed: claimed) {
                    node.children.append(sub)
                    node.mass &+= sub.mass
                    if sub.notCandidate { node.notCandidate = true }
                }
            } else if child.size >= minBytes {
                node.files.append(BigFile(info: child))
                node.mass &+= UInt64(max(0, child.size))
            }
        }
        // `.git` bulunan klasör (git kökü): adaylık dışı, çocuklara bakılır.
        node.isGitRoot = FS.info(FS.join(dir.path, ".git")) != nil
        return node.mass == 0 && !node.notCandidate ? nil : node
    }

    // MARK: - Aday seçimi

    /// Klasör adayı mı, yoksa tek tek dosyalara mı inilir?
    private func emit(_ node: DirNode, context: ScanContext, items: inout [CleanItem]) async throws {
        try context.checkCancellation()
        let protected = context.pathPolicy.protectionReason(for: node.info.url) != nil
        let dominantChild = node.children.contains { $0.mass * 10 >= node.mass * 8 }
        if !protected, !node.isGitRoot, !node.notCandidate, node.mass >= folderCandidateBytes, !dominantChild {
            // Görünen boyut seyrek dosyalardan şişmiş olabilir: ayrılan boyut da eşiği aşmalı.
            let item = try await folderItem(node, context: context)
            if item.allocatedBytes >= folderCandidateBytes {
                items.append(item)
                return
            }
        }
        for f in node.files {
            if let item = try await fileItem(f.info, context: context) { items.append(item) }
        }
        for child in node.children {
            try await emit(child, context: context, items: &items)
        }
    }

    private func folderItem(_ node: DirNode, context: ScanContext) async throws -> CleanItem {
        let m = try await context.sizeMeter.measure(node.info.url)
        let bigCount = Self.countFiles(node)
        return CleanItem(
            category: .largeOld,
            name: node.info.name,
            path: node.info.path,
            allocatedBytes: m.allocatedBytes,
            risk: .red,
            dateSignal: context.signals.dateSignal(for: node.info.url, now: context.now),
            note: "Kural dışı büyük klasör (\(bigCount) büyük dosya). Karar sizde.",
            method: .trash
        )
    }

    private static func countFiles(_ n: DirNode) -> Int {
        n.files.count + n.children.reduce(0) { $0 + countFiles($1) }
    }

    private func fileItem(_ f: FSInfo, context: ScanContext) async throws -> CleanItem? {
        try context.checkCancellation()
        let m = try await context.sizeMeter.measure(f.url)
        let allocated = m.allocatedBytes
        let logical = UInt64(max(0, f.size))
        let date = context.signals.dateSignal(for: f.url, now: context.now)

        // Seyrek dosya: görünen büyük, ayrılan çok küçük.
        if allocated < minFileBytes {
            if logical < minFileBytes { return nil }
            return CleanItem(
                category: .largeOld,
                name: f.name,
                path: f.path,
                allocatedBytes: allocated,
                risk: .info,
                dateSignal: date,
                note: "Seyrek dosya: görünen \(Self.format(logical)), diskte ayrılan \(Self.format(allocated)). Gerçek kazanç ayrılan boyuttur.",
                method: .none
            )
        }

        let ext = (f.name as NSString).pathExtension.lowercased()
        let downloads = FS.join(PathUtil.canonicalDirectory(context.home), "Downloads") + "/"
        if Self.installerExtensions.contains(ext), f.path.hasPrefix(downloads) {
            return CleanItem(
                category: .largeOld, name: f.name, path: f.path, allocatedBytes: allocated,
                risk: .yellow, dateSignal: date,
                note: "Kurulum/arşiv dosyası (İndirilenler); gerekirse yeniden indirilir.", method: .trash
            )
        }
        return CleanItem(
            category: .largeOld, name: f.name, path: f.path, allocatedBytes: allocated,
            risk: .red, dateSignal: date,
            note: "Kural dışı büyük dosya. Karar sizde.", method: .trash
        )
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// `rules.json` yollarının (glob açılmış) standart yolları: bu yollar başka tarayıcının alanıdır.
    private static func ruleCoveredPaths(_ context: ScanContext) -> Set<String> {
        var set = Set<String>()
        for rule in context.rules {
            for url in PathExpander.glob(rule.path, home: context.home) {
                set.insert(PathUtil.canonical(url))
            }
        }
        return set
    }
}
