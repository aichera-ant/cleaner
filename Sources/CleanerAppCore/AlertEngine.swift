import Foundation

/// Bir boş alan örneği.
public struct DiskSample: Sendable, Equatable {
    public var date: Date
    public var availableBytes: UInt64
    public var totalBytes: UInt64
    public init(date: Date, availableBytes: UInt64, totalBytes: UInt64) {
        self.date = date
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
    }
}

/// Sınırlı örnek geçmişi: son 24 saat ve en çok 400 örnek (5 dakikalık aralıkta ~288). Yalnız bellekte.
public struct DiskHistory: Sendable, Equatable {
    public static let retention: TimeInterval = 24 * 3600
    public static let maxCount = 400
    public private(set) var samples: [DiskSample] = []

    public init() {}

    /// Örnek ekler. Saat geriye alındıysa (gelecekteki örnekler) bu örnekler atılır; eski olanlar ve fazlası budanır.
    public mutating func add(_ s: DiskSample, now: Date) {
        samples.removeAll { $0.date > now }
        samples.removeAll { now.timeIntervalSince($0.date) > Self.retention }
        samples.append(s)
        if samples.count > Self.maxCount { samples.removeFirst(samples.count - Self.maxCount) }
    }

    /// `[now - window, now]` aralığındaki en yüksek boş alan.
    public func maxAvailable(within window: TimeInterval, now: Date) -> UInt64? {
        samples.filter { $0.date <= now && now.timeIntervalSince($0.date) <= window }.map(\.availableBytes).max()
    }
}

public struct NotificationAlert: Sendable, Equatable {
    public enum Kind: String, Sendable { case lowSpace, rapidDrop, weeklySummary }
    public var kind: Kind
    public var title: String
    public var body: String
}

/// Kalıcı uyarı durumu (tekrarı önlemek için).
public struct AlertState: Codable, Sendable, Equatable {
    /// Eşik uyarısının son gönderildiği gün (günün başlangıcı).
    public var lowLastDay: Date?
    /// Son uyarıdan sonra alan eşiğin (payıyla) üstüne çıktı mı: aynı gün içinde yeniden uyarmaya izin verir.
    public var lowRearm = true
    /// Hızlı düşüş olayı sürüyor (uyarı verildi ya da ayar kapalıyken görüldü).
    public var rapidActive = false
    public var weeklyLast: Date?
    public var weeklyAttempt: Date?
    public init() {}
}

public enum WeeklyAction: Equatable, Sendable {
    case wait
    /// İlk kez görüldü: sayacı şimdiye kur, taramayı bir hafta sonra yap.
    case schedule
    case run
}

/// Uyarı kararları; saf. Saat, takvim ve disk okuması dışarıdan verilir.
public enum AlertEngine {
    public static let rapidWindow: TimeInterval = 3600
    public static let weeklyInterval: TimeInterval = 7 * 24 * 3600
    public static let weeklyRetryGap: TimeInterval = 6 * 3600

    /// Eşik: GB ya da yüzdeden hangisine önce inilirse; yani ikisinden büyüğü.
    public static func lowThreshold(total: UInt64, settings s: BackgroundSettings) -> UInt64 {
        let pct = UInt64(Double(total) * Double(s.lowSpacePercent) / 100)
        return max(s.lowSpaceBytes, pct)
    }

    public struct DiskDecision: Equatable, Sendable {
        public var alerts: [NotificationAlert]
        public var state: AlertState
    }

    /// `history` örneği (`sample`) zaten içerir.
    public static func evaluateDisk(sample: DiskSample, history: DiskHistory, settings s: BackgroundSettings,
                                    state: AlertState, now: Date, calendar: Calendar) -> DiskDecision {
        var st = state
        var alerts: [NotificationAlert] = []

        // 1) Eşik altı
        let threshold = lowThreshold(total: sample.totalBytes, settings: s)
        let today = calendar.startOfDay(for: now)
        if sample.availableBytes < threshold {
            if s.lowSpaceEnabled, st.lowLastDay != today || st.lowRearm {
                alerts.append(NotificationAlert(kind: .lowSpace, title: "Boş alan azaldı",
                                    body: "Mac'inde \(Fmt.bytes(sample.availableBytes)) boş alan kaldı. Cleaner ile neleri temizleyebileceğine bakabilirsin."))
                st.lowLastDay = today
                st.lowRearm = false
            }
        } else if sample.availableBytes >= threshold + max(threshold / 10, 1) {
            st.lowRearm = true
        }

        // 2) Hızlı düşüş
        let peak = history.maxAvailable(within: rapidWindow, now: now) ?? sample.availableBytes
        let drop = peak > sample.availableBytes ? peak - sample.availableBytes : 0
        if drop >= s.rapidDropBytes {
            if !st.rapidActive, s.rapidDropEnabled {
                alerts.append(NotificationAlert(kind: .rapidDrop, title: "Boş alan hızla azalıyor",
                                    body: "Son 1 saatte yaklaşık \(Fmt.bytes(drop)) azaldı; şu an \(Fmt.bytes(sample.availableBytes)) boş."))
            }
            st.rapidActive = true
        } else {
            st.rapidActive = false
        }
        return DiskDecision(alerts: alerts, state: st)
    }

    public static func weeklyAction(settings s: BackgroundSettings, state: AlertState, now: Date) -> WeeklyAction {
        guard s.weeklyEnabled else { return .wait }
        guard let last = state.weeklyLast else { return .schedule }
        // Saat geriye alındıysa (son çalışma gelecekte) sayacı yeniden kur.
        if last > now { return .schedule }
        guard now.timeIntervalSince(last) >= weeklyInterval else { return .wait }
        if let attempt = state.weeklyAttempt, attempt <= now, now.timeIntervalSince(attempt) < weeklyRetryGap { return .wait }
        return .run
    }

    public static func weeklyAlert(cleanableBytes: UInt64, settings s: BackgroundSettings) -> NotificationAlert? {
        guard cleanableBytes >= s.weeklyMinBytes else { return nil }
        return NotificationAlert(kind: .weeklySummary, title: "Haftalık özet",
                     body: "Yaklaşık \(Fmt.bytes(cleanableBytes)) güvenle temizlenebilir. Bakmak için aç.")
    }
}

extension Fmt {
    /// Menü çubuğu için kısa boyut: "48 GB", "4,2 GB", "1,2 TB" (ondalık birimler, virgül ayracı).
    public static func shortBytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1e9
        func num(_ v: Double, _ digits: Int) -> String {
            let f = NumberFormatter()
            f.locale = Locale(identifier: "tr_TR")
            f.minimumFractionDigits = digits
            f.maximumFractionDigits = digits
            return f.string(from: NSNumber(value: v)) ?? "\(v)"
        }
        if gb >= 1000 { return num(gb / 1000, 1) + " TB" }
        if gb >= 10 { return num(gb.rounded(), 0) + " GB" }
        if gb >= 0.1 { return num(gb, 1) + " GB" }
        return num(Double(b) / 1e6, 0) + " MB"
    }
}
