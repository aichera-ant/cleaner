import Foundation

/// Tarama sonucu.
public struct ScanReport: Codable, Sendable {
    public struct ScannerError: Codable, Sendable, Equatable {
        public var scanner: String
        public var message: String
    }

    public struct Dropped: Codable, Sendable, Equatable {
        public var path: String
        public var reason: String
    }

    /// Boyuta göre azalan sırada.
    public var items: [CleanItem]
    public var errors: [ScannerError]
    /// Korunan yol olduğu için atılan öğeler.
    public var dropped: [Dropped]

    public func totalsByCategory() -> [(Category, UInt64)] {
        var t: [Category: UInt64] = [:]
        for i in items { t[i.category, default: 0] &+= i.allocatedBytes }
        return Category.allCases.compactMap { c in t[c].map { (c, $0) } }
    }
}

/// Tarayıcıları çalıştırır ve sonuçları tek, tutarlı bir listede birleştirir:
///
/// 1. Korunan yollar atılır.
/// 2. Aynı yol (aynı id): en kısıtlayıcı öğe kazanır (kilitli > bilgi > kırmızı > sarı > yeşil); eşitlikte
///    kayıt sırası. Varsayılan seçim kapatılmışsa (`preselect == false`) birleşen öğede de kapalı kalır.
/// 3. Alt ağacında (uygulama artıkları dahil) kilitli ya da bilgi öğesi olan öğe kilitlenir.
/// 4. İç içe öğeler çift sayılmaz: daha özel kategori kazanır (`specificity`); eşitlikte üst öğe kalır.
///    Kilitli/bilgi alt öğe atılmaz (üst öğe zaten kilitlenmiştir).
///
/// Aşamalar: `phase == 0` tarayıcılar paralel çalışır; `phase >= 1` tarayıcılar ardından, ilk aşamanın
/// yolları `context.claimedPaths` içinde verilerek çalışır.
public struct ScanEngine: Sendable {
    public var registry: CleanerRegistry

    public init(registry: CleanerRegistry = .makeDefault()) {
        self.registry = registry
    }

    /// - Parameters:
    ///   - categories: yalnız bu kategoriler raporlanır.
    ///   - fullLockCheck: true (varsayılan) ise kategori süzgeci verilse de BÜTÜN tarayıcılar çalışır; kilit ve
    ///     çift sayım hesabı tam taramaya göre yapılır, süzgeç en sonda uygulanır. false yalnız hızlı
    ///     görüntüleme içindir (`scan --category`); taşıma kararı için kullanılmaz.
    public func scan(_ context: ScanContext, categories: Set<Category>? = nil, fullLockCheck: Bool = true) async throws -> ScanReport {
        // Arayüz unutsa bile: bu süreçte (ve devralan alt süreçlerde) dataless dosya okunarak indirilmez.
        CloudGuard.disableDatalessMaterializationForProcess()
        let selected = registry.cleaners.enumerated().filter { _, c in
            fullLockCheck || (categories.map { !$0.isDisjoint(with: c.categories) } ?? true)
        }
        typealias Partial = (Int, [CleanItem], ScanReport.ScannerError?)
        var partials: [Partial] = []
        var phaseContext = context
        for phase in Set(selected.map { $0.element.phase }).sorted() {
            let batch = selected.filter { $0.element.phase == phase }
            let ctx = phaseContext
            try await withThrowingTaskGroup(of: Partial.self) { group in
                for (index, cleaner) in batch {
                    group.addTask {
                        do {
                            return (index, try await cleaner.scan(ctx), nil)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            return (index, [], .init(scanner: cleaner.id, message: String(describing: error)))
                        }
                    }
                }
                for try await p in group { partials.append(p) }
            }
            for (_, list, _) in partials {
                for item in list { for p in item.footprint { phaseContext.claimedPaths.insert(PathUtil.canonicalKey(p)) } }
            }
        }
        partials.sort { $0.0 < $1.0 } // kayıt sırası: eşitlikte ilk kayıtlı tarayıcı kazanır

        var dropped: [ScanReport.Dropped] = []
        var byID: [String: Int] = [:]
        var items: [CleanItem] = []
        for (_, list, _) in partials {
            for item in list {
                if let reason = context.pathPolicy.protectionReason(for: item.url) {
                    dropped.append(.init(path: item.path, reason: reason))
                    continue
                }
                if let i = byID[item.id] {
                    items[i] = Self.merge(items[i], item)
                } else {
                    byID[item.id] = items.count
                    items.append(item)
                }
            }
        }
        items = Self.resolveNesting(items)
        if let categories { items = items.filter { categories.contains($0.category) } }
        items.sort { ($0.allocatedBytes, $1.path) > ($1.allocatedBytes, $0.path) }
        return ScanReport(items: items, errors: partials.compactMap { $0.2 }, dropped: dropped)
    }

    /// Kısıtlayıcılık: kilitli > bilgi > kırmızı > sarı > yeşil.
    static func restrictiveness(_ i: CleanItem) -> Int {
        if i.isLocked { return 4 }
        switch i.risk {
        case .locked: return 4
        case .info: return 3
        case .red: return 2
        case .yellow: return 1
        case .green: return 0
        }
    }

    /// Aynı yoldaki iki öğeden en kısıtlayıcısı (eşitlikte `a`, yani önce kayıtlı olan).
    static func merge(_ a: CleanItem, _ b: CleanItem) -> CleanItem {
        var winner = restrictiveness(b) > restrictiveness(a) ? b : a
        let loser = winner == a ? b : a
        if loser.preselect == false { winner.preselect = false }
        return winner
    }

    /// Kategori özgüllüğü: büyük ve eski en genel, sonra klasörler ve mükerrer; diğerleri özel.
    static func specificity(_ c: Category) -> Int {
        switch c {
        case .largeOld: 0
        case .folders, .duplicates: 1
        case .xcode, .projectArtifacts, .caches, .docker, .oldVersions, .apps: 2
        }
    }

    static func isBlocking(_ i: CleanItem) -> Bool { i.isLocked || i.risk == .info }

    /// Kilit yayılımı ve çift sayım. Docker sanal yolları (diskte yok) iç içe hesaba girmez.
    static func resolveNesting(_ input: [CleanItem]) -> [CleanItem] {
        var items = input
        // Ayak izi anahtarı -> öğe indeksleri.
        var owners: [String: [Int]] = [:]
        var keys: [[String]] = []
        for (i, item) in items.enumerated() {
            let ks = item.path.hasPrefix("/docker/") ? [] : item.footprint.map(PathUtil.canonicalKey)
            keys.append(ks)
            for k in ks { owners[k, default: []].append(i) }
        }
        // (kapsayan, kapsanan) çiftleri: kapsananın her ayak izi anahtarının kendisi ve ataları aranır.
        var pairs: [(outer: Int, inner: Int)] = []
        var seenPairs = Set<[Int]>()
        for (d, ks) in keys.enumerated() {
            for k in ks {
                var p = k
                while true {
                    for a in owners[p] ?? [] where a != d && seenPairs.insert([a, d]).inserted {
                        pairs.append((a, d))
                    }
                    guard p != "/", let slash = p.lastIndex(of: "/") else { break }
                    p = slash == p.startIndex ? "/" : String(p[..<slash])
                }
            }
        }
        if pairs.isEmpty { return items }

        // 3) Kilit yayılımı (kapsanan kilitli/bilgi ise kapsayan kilitlenir). Sabit noktaya kadar.
        var changed = true
        while changed {
            changed = false
            for (a, d) in pairs where isBlocking(items[d]) && !isBlocking(items[a]) {
                items[a] = items[a].locked("İçinde kullanımdaki öğe var: \(items[d].path)")
                changed = true
            }
        }

        // 4) Çift sayım: kaybeden atılır.
        var drop = Set<Int>()
        for (a, d) in pairs {
            let (sa, sd) = (specificity(items[a].category), specificity(items[d].category))
            let equalPath = keys[a].contains(keys[d].first ?? "") || keys[d].contains(keys[a].first ?? "")
            let loser: Int
            if sa != sd {
                loser = sa < sd ? a : d // daha genel kategori atılır
            } else if equalPath {
                // Ayak izi eşit (ör. uygulama artığı ile aynı yol): uygulama kalır, diğeri atılır.
                loser = items[a].category == .apps ? d : a
            } else {
                // Aynı özgüllük: üst öğe kapsar. Ama üst öğe taşınamıyorsa (kilitli/bilgi) içindeki
                // temizlenebilir öğe ayrıca önerilir.
                if isBlocking(items[a]) { continue }
                loser = d
            }
            // Kilitli/bilgi kapsanan atılmaz (kullanıcı neden kilitli olduğunu görsün; tutulacak kopya kalsın).
            if loser == d && isBlocking(items[d]) { continue }
            drop.insert(loser)
        }
        return items.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }
}
