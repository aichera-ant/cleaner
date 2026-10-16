import Darwin
import Foundation

/// `lstat` ile okunan meta veri. İçerik okunmaz.
struct FSInfo: Sendable {
    var path: String
    var name: String
    var mode: mode_t
    /// Görünen (mantıksal) boyut. Ayrılan boyut için `SizeMeter` kullanılır.
    var size: Int64
    var mtime: TimeInterval
    var dev: dev_t
    var ino: UInt64
    var flags: UInt32

    var isDirectory: Bool { (mode & S_IFMT) == S_IFDIR }
    var isRegular: Bool { (mode & S_IFMT) == S_IFREG }
    var isSymlink: Bool { (mode & S_IFMT) == S_IFLNK }
    var isDataless: Bool { (flags & UInt32(SF_DATALESS)) != 0 }
    var url: URL { URL(fileURLWithPath: path) }
}

enum FS {
    static func info(_ path: String) -> FSInfo? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FSInfo(
            path: path,
            name: (path as NSString).lastPathComponent,
            mode: st.st_mode,
            size: Int64(st.st_size),
            mtime: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9,
            dev: st.st_dev,
            ino: UInt64(st.st_ino),
            flags: st.st_flags
        )
    }

    static func names(in dir: String) -> [String] {
        listing(dir) ?? []
    }

    /// Klasör listesi; listelenemezse (izin, G/Ç hatası) nil. "Boş" ile "okunamadı" ayrımı gereken
    /// yerlerde bu kullanılır.
    static func listing(_ dir: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: dir)
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    /// İçi gezilmeyen paket uzantıları (uygulama paketi, kütüphane paketi).
    static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "imovielibrary", "fcpbundle", "musiclibrary", "tvlibrary", "framework",
        "bundle", "plugin", "kext", "xcarchive", "xcodeproj", "xcworkspace",
    ]

    static func isPackageName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && packageExtensions.contains(ext)
    }
}

/// Dosya sistemi gezgini: yalnız meta veri okur. Sembolik bağlantı izlemez, başka birime geçmez,
/// yalnız bulutta duran (dataless) girdileri ve bulut köklerini hiç açmaz.
struct FileWalker: Sendable {
    var cloudGuard: CloudGuard
    /// Bu adlı klasörlerin içine inilmez (her derinlikte).
    var skipDirNames: Set<String> = []
    /// Tam yolu bu kümede olan klasörlerin ve dosyaların içine inilmez / listelenmez.
    var skipPaths: Set<String> = []
    /// Paket klasörlerinin (*.app vb.) içine inilmez.
    var skipPackages = true

    /// Kök için güvenli başlangıç: sembolik bağlantı çözülür, bulut kökü ya da yoksa nil.
    func rootInfo(_ url: URL) -> FSInfo? {
        // `realpath` ile çözülür (Foundation'ın resolvingSymlinksInPath'ı /private önekini düşürür).
        let resolved = URL(fileURLWithPath: PathUtil.canonicalDirectory(url))
        guard !cloudGuard.isUnderCloudRoot(resolved), let info = FS.info(resolved.path), !info.isDataless else { return nil }
        return info
    }

    /// `dir` klasörünün gezilmesi uygun çocukları: normal dosyalar ve inilebilir klasörler.
    func children(of dir: FSInfo, rootDev: dev_t) throws -> [FSInfo] {
        try listChildren(of: dir, rootDev: rootDev) ?? []
    }

    /// `children` gibi; klasör listelenemezse nil (atlanır, "boş" sayılmaz).
    func listChildren(of dir: FSInfo, rootDev: dev_t) throws -> [FSInfo]? {
        try Task.checkCancellation()
        guard dir.isDirectory, !dir.isDataless else { return [] }
        if cloudGuard.isUnderCloudRoot(dir.url) { return [] }
        guard let names = FS.listing(dir.path) else { return nil }
        var out: [FSInfo] = []
        for name in names {
            let path = FS.join(dir.path, name)
            if skipPaths.contains(path) { continue }
            guard let info = FS.info(path), !info.isSymlink, !info.isDataless else { continue }
            if info.isDirectory {
                if skipDirNames.contains(name) { continue }
                if skipPackages && FS.isPackageName(name) { continue }
                if info.dev != rootDev { continue }
                out.append(info)
            } else if info.isRegular {
                out.append(info)
            }
        }
        return out
    }
}

/// Sınırlı eşzamanlılıkla sıralı eşleme.
func boundedParallelMap<T: Sendable, R: Sendable>(
    _ items: [T], width: Int, _ transform: @escaping @Sendable (T) throws -> R
) async throws -> [R] {
    var results = [R?](repeating: nil, count: items.count)
    try await withThrowingTaskGroup(of: (Int, R).self) { group in
        var next = 0
        func addNext(_ group: inout ThrowingTaskGroup<(Int, R), any Error>) {
            let i = next
            next += 1
            let item = items[i]
            group.addTask {
                try Task.checkCancellation()
                return (i, try transform(item))
            }
        }
        while next < min(width, items.count) { addNext(&group) }
        while let (i, r) = try await group.next() {
            results[i] = r
            if next < items.count { addNext(&group) }
        }
    }
    return results.map { $0! }
}
