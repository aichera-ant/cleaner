import Darwin
import Foundation

/// Docker nesneleri (yalnız `docker` CLI ile) ve colima disk dosyaları (bilgi).
///
/// Docker nesnelerinin diskte yolu yoktur; öğe yolu `/docker/<tür>/<kimlik>` sanal yoludur ve yalnız
/// kimlik amaçlıdır. Temizleme her zaman `.command` ile yapılır, Çöp Kutusu'na gönderilmez.
public struct DockerScanner: Cleaner {
    public let id = "docker"
    public var categories: Set<Category> { [.docker] }

    public init() {}

    public func scan(_ context: ScanContext) async throws -> [CleanItem] {
        var items = try await colimaDisks(context)
        items += try await dockerObjects(context)
        return items
    }

    // MARK: Docker nesneleri

    private func dockerObjects(_ context: ScanContext) async throws -> [CleanItem] {
        let cmds = context.signals.commands
        // Docker yoksa ya da kapalıysa (daemon yanıt vermiyor) sessizce boş dön.
        guard let ps = await cmds.run("docker", ["ps", "-a", "--format", "{{json .}}"], timeout: .seconds(8)),
              ps.succeeded else { return [] }

        var items: [CleanItem] = []
        for row in Self.jsonLines(ps.stdout) {
            try context.checkCancellation()
            guard let id = row["ID"] as? String, Self.isSafeToken(id), CommandPolicy.isHex(id) else { continue }
            let name = (row["Names"] as? String) ?? id
            let state = (row["State"] as? String) ?? ""
            let size = Self.parseSize((row["Size"] as? String)?.split(separator: " ").first.map(String.init) ?? "")
            let running = state == "running" || state == "restarting" || state == "paused"
            // Durmuş container sarı ve seçili değil: yazılabilir katmanında (container içinde yazılan dosyalar)
            // veri olabilir ve `docker rm` kalıcı siler.
            items.append(CleanItem(
                category: .docker, name: "Container: \(name)", path: CommandPolicy.dockerPath(.container, id),
                allocatedBytes: size, risk: running ? .locked : .yellow,
                lockReason: running ? "container çalışıyor (\(state))" : nil,
                note: running ? nil : "Durmuş container (\(row["Status"] as? String ?? state)); kalıcı silinir (Çöp Kutusu'na gitmez). Container içinde yazılmış dosyalar (yazılabilir katman) varsa onlar da gider; imaj kalır.",
                method: .command(CommandPolicy.dockerCommand(.container, id)),
                preselect: false
            ))
        }

        guard let df = await cmds.run("docker", ["system", "df", "-v", "--format", "json"], timeout: .seconds(30)),
              df.succeeded,
              let root = try? JSONSerialization.jsonObject(with: Data(df.stdout.utf8)) as? [String: Any]
        else { return items }

        // Kullanılmayan imajlar.
        for img in (root["Images"] as? [[String: Any]]) ?? [] {
            guard (img["Containers"] as? String) == "0" else { continue }
            guard let rawID = img["ID"] as? String else { continue }
            let id = rawID.replacingOccurrences(of: "sha256:", with: "")
            guard Self.isSafeToken(id), CommandPolicy.isHex(id) else { continue }
            let repo = (img["Repository"] as? String) ?? "<none>"
            let tag = (img["Tag"] as? String) ?? ""
            let ref = tag.isEmpty || tag == "<none>" ? repo : "\(repo):\(tag)"
            let size = Self.parseSize((img["UniqueSize"] as? String).flatMap { $0 == "N/A" ? nil : $0 } ?? (img["Size"] as? String) ?? "")
            items.append(CleanItem(
                category: .docker, name: "İmaj: \(ref)", path: CommandPolicy.dockerPath(.image, id),
                allocatedBytes: size, risk: .yellow,
                note: "Hiçbir container kullanmıyor; gerektiğinde yeniden indirilir.",
                method: .command(CommandPolicy.dockerCommand(.image, id))
            ))
        }

        // Sahipsiz (dangling) volume'lar: kırmızı, kullanıcı verisi olabilir.
        var sizes: [String: UInt64] = [:]
        for v in (root["Volumes"] as? [[String: Any]]) ?? [] {
            if let n = v["Name"] as? String { sizes[n] = Self.parseSize((v["Size"] as? String) ?? "") }
        }
        if let ls = await cmds.run("docker", ["volume", "ls", "-f", "dangling=true", "--format", "{{json .}}"], timeout: .seconds(8)),
           ls.succeeded {
            for row in Self.jsonLines(ls.stdout) {
                guard let name = row["Name"] as? String, Self.isSafeToken(name) else { continue }
                items.append(CleanItem(
                    category: .docker, name: "Volume: \(name.count > 24 ? String(name.prefix(12)) + "…" : name)",
                    path: CommandPolicy.dockerPath(.volume, name), allocatedBytes: sizes[name] ?? 0, risk: .red,
                    note: "Hiçbir container'a bağlı değil ama veritabanı gibi veri içerebilir; silinince geri gelmez.",
                    method: .command(CommandPolicy.dockerCommand(.volume, name))
                ))
            }
        }

        // Build cache: tek öğe.
        let cache = (root["BuildCache"] as? [[String: Any]]) ?? []
        let cacheBytes = cache.reduce(UInt64(0)) { $0 &+ Self.parseSize(($1["Size"] as? String) ?? "") }
        if !cache.isEmpty {
            let inUse = cache.contains { ($0["InUse"] as? Bool) == true || ($0["InUse"] as? String) == "true" }
            items.append(CleanItem(
                category: .docker, name: "Docker build cache", path: CommandPolicy.dockerBuildCachePath,
                allocatedBytes: cacheBytes, risk: .green,
                lockReason: inUse ? "derleme sürüyor" : nil,
                note: "İmaj derleme önbelleği; sonraki derleme daha yavaş olur.",
                method: .command(CommandPolicy.dockerBuildCacheCommand)
            ))
        }
        return items
    }

    // MARK: colima (bilgi)

    private func colimaDisks(_ context: ScanContext) async throws -> [CleanItem] {
        let base = context.home.appending(path: ".colima")
        var files: [URL] = []
        let fm = FileManager.default
        func collect(_ dir: URL, depth: Int) {
            guard depth <= 3, let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for n in names.sorted() {
                let u = dir.appending(path: n)
                var st = stat()
                guard lstat(u.path, &st) == 0 else { continue }
                if (st.st_mode & S_IFMT) == S_IFDIR { collect(u, depth: depth + 1) }
                else if (st.st_mode & S_IFMT) == S_IFREG, n == "datadisk" || n == "diffdisk" { files.append(u) }
            }
        }
        collect(base, depth: 0)

        var items: [CleanItem] = []
        for f in files {
            try context.checkCancellation()
            var st = stat()
            guard lstat(f.path, &st) == 0 else { continue }
            let apparent = UInt64(max(0, st.st_size))
            let m = try await context.sizeMeter.measure(f)
            let rel = f.path.replacingOccurrences(of: base.path + "/", with: "")
            items.append(CleanItem(
                category: .docker, name: "colima disk: \(rel)", path: f.path,
                allocatedBytes: m.allocatedBytes, risk: .info, dateSignal: XcodeScanner.modified(m, context),
                note: "Seyrek dosya: görünen \(Self.human(apparent)), diskte ayrılan \(Self.human(m.allocatedBytes)). Taşınamaz.",
                method: .none
            ))
        }
        return items
    }

    // MARK: Yardımcılar

    static func jsonLines(_ s: String) -> [[String: Any]] {
        s.split(whereSeparator: \.isNewline).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    static func isSafeToken(_ s: String) -> Bool { XcodeScanner.isSafeToken(s) }

    /// "587MB", "1.39GB", "86kB", "0B" (Docker ondalık birim kullanır).
    static func parseSize(_ s: String) -> UInt64 {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let idx = t.firstIndex(where: { !($0.isNumber || $0 == ".") }), idx != t.startIndex,
              let value = Double(t[..<idx]) else { return 0 }
        let mult: Double = switch t[idx...].lowercased() {
        case "b": 1
        case "kb": 1e3
        case "mb": 1e6
        case "gb": 1e9
        case "tb": 1e12
        default: 0
        }
        return UInt64(value * mult)
    }

    static func human(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
