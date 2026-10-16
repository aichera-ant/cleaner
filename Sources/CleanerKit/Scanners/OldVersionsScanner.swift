import Foundation

/// Eski sürümler: Claude Code, editör eklentileri, fnm/nvm Node sürümleri.
public struct OldVersionsScanner: Cleaner {
    public let id = "oldVersions"
    public var categories: Set<Category> { [.oldVersions] }

    public init() {}

    public func scan(_ context: ScanContext) async throws -> [CleanItem] {
        var items: [CleanItem] = []
        items += try await claudeVersions(context)
        items += try await extensions(context)
        items += try await nodeVersions(context)
        return items
    }

    // MARK: Claude Code

    private func claudeVersions(_ context: ScanContext) async throws -> [CleanItem] {
        let dir = context.home.appending(path: ".local/share/claude/versions")
        let names = Self.entries(dir)
        guard !names.isEmpty else { return [] }
        let newest = names.max { Self.compare($0, $1) < 0 }
        // `~/.local/bin/claude` bağlantısının hedefi de "kullanılan sürüm"dür.
        let linkTarget = (try? FileManager.default.destinationOfSymbolicLink(
            atPath: context.home.appending(path: ".local/bin/claude").path
        )).map { ($0 as NSString).lastPathComponent }
        let running = context.signals.processes.runningProcesses()

        var items: [CleanItem] = []
        for name in names {
            try context.checkCancellation()
            let url = dir.appending(path: name)
            var lock: String?
            if name == newest { lock = "en yüksek sürüm (kullanılan sürüm)" }
            else if name == linkTarget { lock = "claude komutu bu sürüme bağlı" }
            else if running.contains(where: { $0.path?.contains("/claude/versions/\(name)") ?? false }) {
                lock = "bu sürüm şu an çalışıyor"
            }
            items.append(try await item(url, name: "Claude Code \(name)", risk: .green, lock: lock, context: context,
                                        note: "Eski Claude Code sürümü; güncelleme sırasında yedek olarak kalır."))
        }
        return items
    }

    // MARK: Editör eklentileri

    private func extensions(_ context: ScanContext) async throws -> [CleanItem] {
        var dirs = [".vscode/extensions", ".cursor/extensions"].map { context.home.appending(path: $0) }
        let homeNames = (try? FileManager.default.contentsOfDirectory(atPath: context.home.path)) ?? []
        for n in homeNames.sorted() where n.hasPrefix(".antigravity") {
            dirs.append(context.home.appending(path: "\(n)/extensions"))
        }

        var items: [CleanItem] = []
        for dir in dirs {
            // Aynı yayıncı.ad (ve platform soneki) altında sürümleri grupla.
            var groups: [String: [(name: String, version: String)]] = [:]
            for n in Self.entries(dir) {
                guard let p = Self.parseExtension(n) else { continue }
                groups[p.key, default: []].append((n, p.version))
            }
            let editor = dir.deletingLastPathComponent().lastPathComponent
            for (_, versions) in groups.sorted(by: { $0.key < $1.key }) where versions.count > 1 {
                let newest = versions.max { Self.compare($0.version, $1.version) < 0 }!.name
                for v in versions.sorted(by: { $0.name < $1.name }) {
                    try context.checkCancellation()
                    let lock: String? = v.name == newest ? "en yeni sürüm (kullanılan)" : nil
                    items.append(try await item(
                        dir.appending(path: v.name), name: "Eklenti \(v.name) (\(editor))", risk: .green,
                        lock: lock, context: context,
                        note: "Eklentinin eski sürümü; editör yeni sürümü kullanır."
                    ))
                }
            }
        }
        return items
    }

    /// `yayinci.ad-1.2.3[-platform]` → anahtar `yayinci.ad[-platform]`, sürüm `1.2.3`.
    static func parseExtension(_ name: String) -> (key: String, version: String)? {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let i = parts.indices.dropFirst().first(where: { idx in
            let p = parts[idx]
            return p.first?.isNumber == true && p.split(separator: ".").allSatisfy { Int($0) != nil }
        }), parts[0].contains(".") || i > 1 else { return nil }
        let key = (parts[..<i] + parts[(i + 1)...]).joined(separator: "-")
        return (key, parts[i])
    }

    // MARK: Node sürümleri

    private func nodeVersions(_ context: ScanContext) async throws -> [CleanItem] {
        var items: [CleanItem] = []
        let running = context.signals.processes.runningProcesses()

        // fnm
        let fnmRoot = context.home.appending(path: ".local/share/fnm")
        let fnmDir = fnmRoot.appending(path: "node-versions")
        let fnmDefault = (try? FileManager.default.destinationOfSymbolicLink(
            atPath: fnmRoot.appending(path: "aliases/default").path
        )).map { Self.nodeVersionName(fromPath: $0, under: "node-versions") }
        for n in Self.entries(fnmDir) {
            try context.checkCancellation()
            items.append(try await item(
                fnmDir.appending(path: n), name: "Node \(n) (fnm)", risk: .yellow,
                lock: Self.nodeLock(n, isDefault: n == fnmDefault, running: running, marker: "/node-versions/\(n)/"),
                context: context, note: "Kullanılmayan Node sürümü; fnm install ile yeniden kurulur."
            ))
        }

        // nvm
        let nvmDir = context.home.appending(path: ".nvm/versions/node")
        let nvmDefault = nvmDefaultVersion(context)
        for n in Self.entries(nvmDir) {
            try context.checkCancellation()
            items.append(try await item(
                nvmDir.appending(path: n), name: "Node \(n) (nvm)", risk: .yellow,
                lock: Self.nodeLock(n, isDefault: n == nvmDefault, running: running, marker: "/versions/node/\(n)/"),
                context: context, note: "Kullanılmayan Node sürümü; nvm install ile yeniden kurulur."
            ))
        }
        return items
    }

    private func nvmDefaultVersion(_ context: ScanContext) -> String? {
        let alias = context.home.appending(path: ".nvm/alias/default")
        guard let data = try? context.safeReader.readPrefix(alias, bytes: 256),
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        // "v22.1.0" doğrudan; "22" gibi kısmi ise o önekli en yüksek sürüm (aşağıda eşleşmeyle bulunur).
        let installed = Self.entries(context.home.appending(path: ".nvm/versions/node"))
        let wanted = s.hasPrefix("v") ? s : "v" + s
        if installed.contains(wanted) { return wanted }
        return installed.filter { $0.hasPrefix(wanted + ".") }.max { Self.compare($0, $1) < 0 }
    }

    static func nodeVersionName(fromPath p: String, under marker: String) -> String {
        let comps = p.split(separator: "/").map(String.init)
        if let i = comps.firstIndex(of: marker), i + 1 < comps.count { return comps[i + 1] }
        return (p as NSString).lastPathComponent
    }

    static func nodeLock(_ name: String, isDefault: Bool, running: [RunningProcess], marker: String) -> String? {
        if isDefault { return "varsayılan Node sürümü" }
        if running.contains(where: { $0.path?.contains(marker) ?? false }) { return "bu sürüm şu an çalışıyor" }
        return nil
    }

    // MARK: Ortak

    private func item(_ url: URL, name: String, risk: Risk, lock: String?, context: ScanContext, note: String) async throws -> CleanItem {
        let m = try await context.sizeMeter.measure(url)
        var effectiveLock = lock
        if effectiveLock == nil { effectiveLock = XcodeScanner.recentLock(m, context) }
        return CleanItem(
            category: .oldVersions, name: name, path: url.path, allocatedBytes: m.allocatedBytes,
            risk: risk, dateSignal: XcodeScanner.modified(m, context), lockReason: effectiveLock, note: note
        )
    }

    /// Gizli olmayan girdi adları.
    static func entries(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "extensions.json" }.sorted()
    }

    /// Anlamsal sürüm karşılaştırması: sayısal bileşenler sırayla (2.1.300 > 2.1.99). Önde `v` yok sayılır.
    /// Sonuç: eksi (a<b), 0, artı (a>b).
    static func compare(_ a: String, _ b: String) -> Int {
        func nums(_ s: String) -> [Int] {
            let t = s.hasPrefix("v") ? String(s.dropFirst()) : s
            return t.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        }
        let x = nums(a), y = nums(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }
}
