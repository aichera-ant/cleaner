import Foundation

/// Xcode artıkları: DerivedData, Archives, DeviceSupport ve simülatörler.
public struct XcodeScanner: Cleaner {
    public let id = "xcode"
    public var categories: Set<Category> { [.xcode] }

    /// Arşiv ve DeviceSupport için "eski" eşiği (gün).
    public var staleDays = 90

    public init() {}

    public func scan(_ context: ScanContext) async throws -> [CleanItem] {
        var items: [CleanItem] = []
        items += try await derivedData(context)
        items += try await archives(context)
        items += try await deviceSupport(context)
        items += try await simulators(context)
        return items
    }

    // MARK: DerivedData

    /// `<Proje>-<28 küçük harf>` Xcode'un kendi ürettiği ad biçimidir.
    static func isStandardDerivedDataName(_ name: String) -> Bool {
        guard let dash = name.lastIndex(of: "-") else { return false }
        let hash = name[name.index(after: dash)...]
        return name.distance(from: name.startIndex, to: dash) > 0
            && hash.count == 28 && hash.allSatisfy { $0 >= "a" && $0 <= "z" }
    }

    private func derivedData(_ context: ScanContext) async throws -> [CleanItem] {
        let base = context.home.appending(path: "Library/Developer/Xcode/DerivedData")
        var items: [CleanItem] = []
        for url in Self.subdirectories(base) {
            try context.checkCancellation()
            let name = url.lastPathComponent
            let m = try await context.sizeMeter.measure(url)
            let lock = Self.recentLock(m, context)
            let date = Self.modified(m, context)
            if Self.isStandardDerivedDataName(name) {
                let project = String(name[..<name.lastIndex(of: "-")!])
                // Son 1 günde kullanılan ana proje derlemesi önerilir ama varsayılan seçili değil.
                let recent = m.newestModification.map { context.now.timeIntervalSince($0) < 86_400 } ?? false
                items.append(CleanItem(
                    category: .xcode, name: "DerivedData: \(project)", path: url.path,
                    allocatedBytes: m.allocatedBytes, risk: .green, dateSignal: date, lockReason: lock,
                    note: "Xcode derleme çıktısı; sonraki derlemede yeniden oluşur (ilk derleme uzun sürer)."
                        + (recent ? " Son 1 günde kullanıldı; varsayılan seçili değil." : ""),
                    preselect: recent ? false : nil
                ))
            } else if name.hasSuffix(".noindex") || name == "SDKExplicitPrecompiledModules" {
                items.append(CleanItem(
                    category: .xcode, name: "Xcode önbelleği: \(name)", path: url.path,
                    allocatedBytes: m.allocatedBytes, risk: .green, dateSignal: date, lockReason: lock,
                    note: "Xcode önbelleği; yeniden oluşturulur."
                ))
            } else {
                // `-derivedDataPath` ile açılmış ayrı (worktree) derlemeleri: her biri ayrı öğe.
                items.append(CleanItem(
                    category: .xcode, name: "Worktree derlemesi: \(name)", path: url.path,
                    allocatedBytes: m.allocatedBytes, risk: .green, dateSignal: date, lockReason: lock,
                    note: "Standart olmayan ad: `-derivedDataPath` ile açılmış worktree/ajan derlemesi; yeniden oluşur."
                ))
            }
        }
        return items
    }

    // MARK: Archives / DeviceSupport

    private func archives(_ context: ScanContext) async throws -> [CleanItem] {
        let base = context.home.appending(path: "Library/Developer/Xcode/Archives")
        var items: [CleanItem] = []
        for day in Self.subdirectories(base) {
            for url in Self.subdirectories(day) where url.pathExtension == "xcarchive" {
                try context.checkCancellation()
                let m = try await context.sizeMeter.measure(url)
                let age = m.newestModification.map { DateSignal.days(from: $0, to: context.now) }
                guard let age, age >= staleDays else { continue }
                items.append(CleanItem(
                    category: .xcode, name: "Arşiv: \(url.deletingPathExtension().lastPathComponent)", path: url.path,
                    allocatedBytes: m.allocatedBytes, risk: .yellow, dateSignal: .modified(days: age),
                    lockReason: Self.recentLock(m, context),
                    note: "\(staleDays) günden eski Xcode arşivi; sembol dosyaları (dSYM) yalnız burada olabilir, yeniden üretilemez."
                ))
            }
        }
        return items
    }

    private func deviceSupport(_ context: ScanContext) async throws -> [CleanItem] {
        var items: [CleanItem] = []
        for kind in ["iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport"] {
            let base = context.home.appending(path: "Library/Developer/Xcode/\(kind)")
            for url in Self.subdirectories(base) {
                try context.checkCancellation()
                let m = try await context.sizeMeter.measure(url)
                let age = m.newestModification.map { DateSignal.days(from: $0, to: context.now) }
                guard let age, age >= staleDays else { continue }
                items.append(CleanItem(
                    category: .xcode, name: "\(kind): \(url.lastPathComponent)", path: url.path,
                    allocatedBytes: m.allocatedBytes, risk: .yellow, dateSignal: .modified(days: age),
                    lockReason: Self.recentLock(m, context),
                    note: "Cihazdan kopyalanan sistem sembolleri; cihaz yeniden bağlanınca tekrar kopyalanır."
                ))
            }
        }
        return items
    }

    // MARK: Simülatörler

    private func simulators(_ context: ScanContext) async throws -> [CleanItem] {
        guard let result = await context.signals.commands.run(
            "xcrun", ["simctl", "list", "devices", "-j"], timeout: .seconds(15)
        ), result.succeeded,
        let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
        let runtimes = json["devices"] as? [String: Any] else { return [] }

        var items: [CleanItem] = []
        for (runtime, value) in runtimes.sorted(by: { $0.key < $1.key }) {
            guard let devices = value as? [[String: Any]] else { continue }
            for d in devices {
                try context.checkCancellation()
                guard let udid = d["udid"] as? String, CommandPolicy.isUUID(udid) else { continue }
                let name = d["name"] as? String ?? udid
                let state = d["state"] as? String ?? "Unknown"
                let available = d["isAvailable"] as? Bool ?? true
                // Yolu çıktıdan değil kendimiz kurarız (dışarıdan gelen yola güvenme).
                let dir = context.home.appending(path: "Library/Developer/CoreSimulator/Devices/\(udid)")
                guard FileManager.default.fileExists(atPath: dir.path) else { continue }
                let m = try await context.sizeMeter.measure(dir)
                let label = runtime.split(separator: ".").last.map(String.init) ?? runtime
                var lock: String?
                if state != "Shutdown" { lock = "simülatör açık (\(state))" }
                let risk: Risk = available ? .yellow : .green
                items.append(CleanItem(
                    category: .xcode, name: "Simülatör: \(name) (\(label))", path: dir.path,
                    allocatedBytes: m.allocatedBytes, risk: risk, dateSignal: Self.modified(m, context),
                    lockReason: lock,
                    note: available
                        ? "Kullanılabilir simülatör; silinirse uygulama verileri gider, yeniden oluşturulabilir."
                        : "Çalışma zamanı eksik (kullanılamaz) simülatör; kullanılamaz durumda.",
                    method: .command(CommandPolicy.simulatorCommand(udid: udid))
                ))
            }
        }
        return items
    }

    // MARK: Yardımcılar

    /// Komut argümanı olabilecek kimlik: yalnız ASCII, `[A-Za-z0-9]` ile başlar (seçenek gibi okunamaz),
    /// devamı `[A-Za-z0-9._-]`.
    static func isSafeToken(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, isASCIIAlnum(first) else { return false }
        return s.unicodeScalars.allSatisfy { isASCIIAlnum($0) || $0 == "-" || $0 == "_" || $0 == "." }
    }

    static func isASCIIAlnum(_ c: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c)
    }

    static func subdirectories(_ url: URL) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        return names.sorted().compactMap { n in
            let u = url.appending(path: n)
            var st = stat()
            guard lstat(u.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
            return u
        }
    }

    static func recentLock(_ m: SizeMeasurement, _ context: ScanContext) -> String? {
        if let d = m.newestModification, context.now.timeIntervalSince(d) < 3600 { return "son 1 saatte değişti" }
        return nil
    }

    static func modified(_ m: SizeMeasurement, _ context: ScanContext) -> DateSignal {
        m.newestModification.map { .modified(days: DateSignal.days(from: $0, to: context.now)) } ?? .unknown
    }
}
