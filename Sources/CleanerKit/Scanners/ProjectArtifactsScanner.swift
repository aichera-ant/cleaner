import Foundation

/// Proje klasörlerindeki yeniden oluşan çıktılar: node_modules, .next, .turbo, dist/build.
public struct ProjectArtifactsScanner: Cleaner {
    public let id = "projectArtifacts"
    public var categories: Set<Category> { [.projectArtifacts] }

    /// Köklerden en çok bu kadar klasör aşağıya inilir (kökün çocukları derinlik 1).
    public var maxDepth = 4
    /// Proje etkinliği bu günden eskiyse "eski" sayılır.
    public var staleDays = 30

    public init() {}

    static let projectMarkers = ["package.json", ".git", "Package.swift"]
    /// Altına inilmeyen klasörler.
    static let skipDescent: Set<String> = [
        "node_modules", "Pods", "DerivedData", ".build", "build", "dist", "vendor", "Library", ".Trash",
    ]

    public func scan(_ context: ScanContext) async throws -> [CleanItem] {
        var projects: [URL] = []
        var seen = Set<String>()
        for root in context.roots {
            collectProjects(root, depth: 0, context: context, into: &projects, seen: &seen)
        }
        var items: [CleanItem] = []
        var gitCache: [String: GitContext] = [:]
        for project in projects {
            try context.checkCancellation()
            items += try await artifacts(in: project, context: context, gitCache: &gitCache)
        }
        return items
    }

    // MARK: Proje bulma

    private func collectProjects(_ dir: URL, depth: Int, context: ScanContext, into out: inout [URL], seen: inout Set<String>) {
        guard depth <= maxDepth else { return }
        let key = PathUtil.key(PathUtil.canonical(dir))
        guard seen.insert(key).inserted else { return }
        if context.cloudGuard.isUnderCloudRoot(dir) { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        if Self.projectMarkers.contains(where: { names.contains($0) }) { out.append(dir) }
        for n in names.sorted() {
            if n.hasPrefix(".") || Self.skipDescent.contains(n) { continue }
            let child = dir.appending(path: n)
            var st = stat()
            guard lstat(child.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            collectProjects(child, depth: depth + 1, context: context, into: &out, seen: &seen)
        }
    }

    // MARK: Git bağlamı

    struct GitContext {
        var info: GitInfo?
        var lastCommit: Date?
    }

    /// Projeyi içeren en yakın `.git` sahibi klasör (yoksa nil).
    private func repoRoot(of project: URL) -> URL? {
        var dir = project
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir.appending(path: ".git").path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || parent.path == "/" { return nil }
            dir = parent
        }
        return nil
    }

    private func gitContext(repo: URL, context: ScanContext, cache: inout [String: GitContext]) async -> GitContext {
        if let c = cache[repo.path] { return c }
        let info = await context.signals.git.info(repo: repo)
        var last: Date?
        if info != nil, let r = await context.signals.commands.run(
            "git", ["-C", repo.path, "log", "-1", "--format=%ct"], timeout: .seconds(10)
        ), r.succeeded, let secs = TimeInterval(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            last = Date(timeIntervalSince1970: secs)
        }
        let c = GitContext(info: info, lastCommit: last)
        cache[repo.path] = c
        return c
    }

    // MARK: Öğeler

    private func artifacts(in project: URL, context: ScanContext, gitCache: inout [String: GitContext]) async throws -> [CleanItem] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: project.path) else { return [] }
        let hasPackageJSON = names.contains("package.json")

        var candidates: [(name: String, kind: Kind)] = []
        for n in names.sorted() {
            switch n {
            case "node_modules": candidates.append((n, .node))
            case ".next", ".turbo": candidates.append((n, .cache))
            case "dist", "build": if hasPackageJSON { candidates.append((n, .output)) }
            default: if n.hasPrefix(".next-") { candidates.append((n, .cache)) }
            }
        }
        // Dosya olan "build" vb. atlanır; yalnız klasör.
        candidates = candidates.filter { c in
            var st = stat()
            return lstat(project.appending(path: c.name).path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
        }
        guard !candidates.isEmpty else { return [] }

        let repo = repoRoot(of: project)
        let git: GitContext = if let repo { await gitContext(repo: repo, context: context, cache: &gitCache) } else { GitContext() }
        let artifactNames = Set(candidates.map(\.name))
        let activity = projectActivity(project, names: names, excluding: artifactNames, lastCommit: git.lastCommit, context: context)
        let ageDays = DateSignal.days(from: activity, to: context.now)
        let projectName = project.lastPathComponent

        var items: [CleanItem] = []
        for c in candidates {
            try context.checkCancellation()
            let url = project.appending(path: c.name)
            var risk: Risk = .green
            var notes: [String] = []

            switch c.kind {
            case .node: notes.append("Yeniden kurulur (npm/pnpm install).")
            case .cache: notes.append("Derleme önbelleği; yeniden oluşur.")
            case .output:
                guard let state = await outputState(c.name, project: project, hasRepo: repo != nil, context: context) else { continue }
                switch state {
                case .tracked: continue // git'te takipli: kullanıcı verisi, öğe olmaz
                case .ignored: notes.append("Derleme çıktısı (git yok sayıyor); yeniden üretilir.")
                case .untracked:
                    risk = .yellow
                    notes.append("Derleme çıktısı ama git yok sayma kuralı yok; kaynakta üretilemiyorsa kaybolur.")
                }
            }
            if ageDays < staleDays {
                notes.append("Proje \(ageDays) gün önce etkindi (\(staleDays) günden yeni).")
            }
            if let info = git.info, info.hasUniqueWork {
                var why: [String] = []
                if info.isDirty { why.append("commit edilmemiş değişiklik") }
                if info.hasUnpushedCommits { why.append("push edilmemiş commit") }
                notes.append("Git deposunda \(why.joined(separator: " ve ")) var; bu klasör yeniden oluştuğu için etkilenmez, kaynak dosyalara dokunulmaz.")
            }

            let m = try await context.sizeMeter.measure(url)
            items.append(CleanItem(
                category: .projectArtifacts,
                name: "\(c.name) (\(projectName))",
                path: url.path,
                allocatedBytes: m.allocatedBytes,
                risk: risk,
                dateSignal: .modified(days: ageDays),
                lockReason: XcodeScanner.recentLock(m, context),
                note: notes.joined(separator: " ")
            ))
        }
        return items
    }

    enum Kind { case node, cache, output }
    enum OutputState { case tracked, ignored, untracked }

    /// `dist`/`build` git'te takipli mi, yok sayılıyor mu? Belirlenemezse nil (öğe üretilmez).
    private func outputState(_ name: String, project: URL, hasRepo: Bool, context: ScanContext) async -> OutputState? {
        guard hasRepo else { return .ignored } // git yok: takip edilemez, package.json var
        let cmds = context.signals.commands
        guard let ls = await cmds.run("git", ["-C", project.path, "ls-files", "--", name], timeout: .seconds(10)),
              ls.succeeded else { return nil }
        if !ls.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .tracked }
        guard let ci = await cmds.run("git", ["-C", project.path, "check-ignore", "-q", "--", name], timeout: .seconds(10)),
              !ci.timedOut else { return nil }
        return ci.exitCode == 0 ? .ignored : .untracked
    }

    /// Proje son etkinliği: son commit ile (artıklar hariç) üst düzey girdilerin en yeni değişikliği.
    private func projectActivity(_ project: URL, names: [String], excluding: Set<String>, lastCommit: Date?, context: ScanContext) -> Date {
        var newest = lastCommit ?? .distantPast
        let dates = context.signals.fileDates
        for n in names where !excluding.contains(n) && n != ".git" && n != ".DS_Store" {
            if let d = dates.dates(project.appending(path: n))?.modified, d > newest { newest = d }
        }
        if newest == .distantPast, let d = dates.dates(project)?.modified { newest = d }
        return min(newest, context.now)
    }
}
