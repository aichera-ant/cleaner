import Darwin
import Foundation

/// Boyut ölçümünün sonucu.
public struct SizeMeasurement: Sendable, Equatable {
    /// Diskte ayrılan toplam bayt (`totalFileAllocatedSize`). Seyrek dosya gerçek boyutuyla sayılır.
    public var allocatedBytes: UInt64
    /// Ağaçtaki en yeni içerik değişikliği (klasörün kendisi dahil). Kilit ve tarih sinyali için.
    public var newestModification: Date?
    /// Sayılan dosya sayısı.
    public var fileCount: Int
    /// İzin hatası vb. nedeniyle okunamayan girdi sayısı.
    public var skippedCount: Int

    public static let zero = SizeMeasurement(allocatedBytes: 0, newestModification: nil, fileCount: 0, skippedCount: 0)

    mutating func merge(_ o: SizeMeasurement) {
        allocatedBytes &+= o.allocatedBytes
        fileCount += o.fileCount
        skippedCount += o.skippedCount
        if let d = o.newestModification, newestModification.map({ d > $0 }) ?? true { newestModification = d }
    }
}

/// Ayrılan boyut ölçer. Yalnız meta veri okur, içerik okumaz.
///
/// - `totalFileAllocatedSizeKey` kullanılır (görünen boyut değil).
/// - Sembolik bağlantı izlenmez (bağlantının kendisi sayılır).
/// - Başka birime (volume) geçilmez.
/// - Dataless (yalnız bulutta) klasörlere inilmez; listelemek bile indirme tetikleyebilir.
/// - Üst düzey alt öğeler paralel ölçülür; iptal edilebilir (`CancellationError`).
/// - İzin hatası çökertmez; `skippedCount` artar.
public struct SizeMeter: Sendable {
    public var maxConcurrency: Int

    public init(maxConcurrency: Int = 8) {
        self.maxConcurrency = max(1, maxConcurrency)
    }

    static let keys: [URLResourceKey] = [
        .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .contentModificationDateKey,
    ]

    /// Tek bir yolun ölçümü.
    public func measure(_ url: URL) async throws -> SizeMeasurement {
        try Task.checkCancellation()
        guard let root = try? url.resourceValues(forKeys: Set(SizeMeter.keys)) else {
            return SizeMeasurement(allocatedBytes: 0, newestModification: nil, fileCount: 0, skippedCount: 1)
        }
        var base = SizeMeasurement(
            allocatedBytes: SizeMeter.allocated(root),
            newestModification: root.contentModificationDate,
            fileCount: root.isDirectory == true && root.isSymbolicLink != true ? 0 : 1,
            skippedCount: 0
        )
        guard root.isDirectory == true, root.isSymbolicLink != true else { return base }
        if CloudGuard.hasDatalessFlag(path: url.path) { return base }
        let volume = SizeMeter.device(url.path)

        // Üst düzey çocuklar (yalnız meta veri).
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: SizeMeter.keys, options: []
            )
        } catch {
            base.skippedCount += 1
            return base
        }

        let limit = maxConcurrency
        let total = try await withThrowingTaskGroup(of: SizeMeasurement.self) { group in
            var acc = base
            var iterator = children.makeIterator()
            var running = 0
            while running < limit, let child = iterator.next() {
                group.addTask { try SizeMeter.walk(child, volume: volume) }
                running += 1
            }
            while let m = try await group.next() {
                acc.merge(m)
                if let child = iterator.next() {
                    group.addTask { try SizeMeter.walk(child, volume: volume) }
                }
            }
            return acc
        }
        return total
    }

    /// Birden çok yolu paralel ölçer. Sonuç girdi sırasındadır.
    public func measure(_ urls: [URL]) async throws -> [SizeMeasurement] {
        var results = [SizeMeasurement](repeating: .zero, count: urls.count)
        try await withThrowingTaskGroup(of: (Int, SizeMeasurement).self) { group in
            for (i, u) in urls.enumerated() {
                group.addTask { (i, try await SizeMeter(maxConcurrency: 2).measure(u)) }
            }
            for try await (i, m) in group { results[i] = m }
        }
        return results
    }

    // MARK: - İç

    /// Bağlantı izlemeden aygıt (birim) numarası.
    static func device(_ path: String) -> dev_t? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_dev : nil
    }

    private static func allocated(_ v: URLResourceValues) -> UInt64 {
        UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
    }

    /// Bir alt ağacı sıralı dolaşır (paralellik üst düzeyde).
    static func walk(_ url: URL, volume: dev_t?) throws -> SizeMeasurement {
        try Task.checkCancellation()
        var m = SizeMeasurement.zero
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else {
            m.skippedCount = 1
            return m
        }
        m.merge(SizeMeasurement(
            allocatedBytes: allocated(v),
            newestModification: v.contentModificationDate,
            fileCount: v.isDirectory == true && v.isSymbolicLink != true ? 0 : 1,
            skippedCount: 0
        ))
        guard v.isDirectory == true, v.isSymbolicLink != true else { return m }
        if let vol = volume, let mine = device(url.path), mine != vol { return m }
        if CloudGuard.hasDatalessFlag(path: url.path) { return m }

        final class Skips: @unchecked Sendable { var n = 0 }
        let skips = Skips()
        guard let e = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in skips.n += 1; return true }
        ) else {
            m.skippedCount += 1
            return m
        }
        var counter = 0
        while let item = e.nextObject() as? URL {
            counter += 1
            if counter % 512 == 0 { try Task.checkCancellation() }
            guard let iv = try? item.resourceValues(forKeys: Set(keys)) else {
                m.skippedCount += 1
                continue
            }
            m.allocatedBytes &+= allocated(iv)
            if let d = iv.contentModificationDate, m.newestModification.map({ d > $0 }) ?? true {
                m.newestModification = d
            }
            if iv.isDirectory == true && iv.isSymbolicLink != true {
                if let vol = volume, let other = device(item.path), other != vol {
                    e.skipDescendants()
                    continue
                }
                if CloudGuard.hasDatalessFlag(path: item.path) { e.skipDescendants() }
            } else {
                m.fileCount += 1
            }
        }
        m.skippedCount += skips.n
        return m
    }
}
