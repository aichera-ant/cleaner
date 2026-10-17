import Foundation
import Observation

/// Arka plan izleme ve bildirim ayarları. Değerler `UserDefaults`ta tutulur; uç değerler sınırlanır.
public struct BackgroundSettings: Equatable, Sendable {
    public static let gigabyte: UInt64 = 1_000_000_000

    public var showInMenuBar = true
    public var launchAtLogin = true
    public var lowSpaceEnabled = true
    /// Eşik: boş alan "şu kadar GB" ya da "toplamın şu kadar yüzdesi"nden hangisine önce inerse.
    public var lowSpaceGB = 20
    public var lowSpacePercent = 10
    public var rapidDropEnabled = true
    /// 1 saatlik pencerede bu kadar GB azalma.
    public var rapidDropGB = 10
    public var weeklyEnabled = true
    /// Haftalık özet için en az temizlenebilir alan (GB).
    public var weeklyMinGB = 1

    public init() {}

    public var lowSpaceBytes: UInt64 { UInt64(lowSpaceGB) * Self.gigabyte }
    public var rapidDropBytes: UInt64 { UInt64(rapidDropGB) * Self.gigabyte }
    public var weeklyMinBytes: UInt64 { UInt64(weeklyMinGB) * Self.gigabyte }

    /// Uç değerleri makul aralığa çeker.
    public func clamped() -> BackgroundSettings {
        var s = self
        s.lowSpaceGB = min(max(s.lowSpaceGB, 1), 2000)
        s.lowSpacePercent = min(max(s.lowSpacePercent, 1), 50)
        s.rapidDropGB = min(max(s.rapidDropGB, 1), 2000)
        s.weeklyMinGB = min(max(s.weeklyMinGB, 1), 2000)
        return s
    }

    enum Key {
        static let showInMenuBar = "bg.showInMenuBar"
        static let launchAtLogin = "bg.launchAtLogin"
        static let lowEnabled = "bg.low.enabled"
        static let lowGB = "bg.low.gb"
        static let lowPercent = "bg.low.percent"
        static let rapidEnabled = "bg.rapid.enabled"
        static let rapidGB = "bg.rapid.gb"
        static let weeklyEnabled = "bg.weekly.enabled"
        static let weeklyMinGB = "bg.weekly.minGB"
    }

    public static func load(from d: UserDefaults) -> BackgroundSettings {
        var s = BackgroundSettings()
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
        s.showInMenuBar = bool(Key.showInMenuBar, s.showInMenuBar)
        s.launchAtLogin = bool(Key.launchAtLogin, s.launchAtLogin)
        s.lowSpaceEnabled = bool(Key.lowEnabled, s.lowSpaceEnabled)
        s.lowSpaceGB = int(Key.lowGB, s.lowSpaceGB)
        s.lowSpacePercent = int(Key.lowPercent, s.lowSpacePercent)
        s.rapidDropEnabled = bool(Key.rapidEnabled, s.rapidDropEnabled)
        s.rapidDropGB = int(Key.rapidGB, s.rapidDropGB)
        s.weeklyEnabled = bool(Key.weeklyEnabled, s.weeklyEnabled)
        s.weeklyMinGB = int(Key.weeklyMinGB, s.weeklyMinGB)
        return s.clamped()
    }

    public func save(to d: UserDefaults) {
        d.set(showInMenuBar, forKey: Key.showInMenuBar)
        d.set(launchAtLogin, forKey: Key.launchAtLogin)
        d.set(lowSpaceEnabled, forKey: Key.lowEnabled)
        d.set(lowSpaceGB, forKey: Key.lowGB)
        d.set(lowSpacePercent, forKey: Key.lowPercent)
        d.set(rapidDropEnabled, forKey: Key.rapidEnabled)
        d.set(rapidDropGB, forKey: Key.rapidGB)
        d.set(weeklyEnabled, forKey: Key.weeklyEnabled)
        d.set(weeklyMinGB, forKey: Key.weeklyMinGB)
    }
}

/// Ayarlar penceresinin bağlandığı gözlenebilir kutu; her değişiklik hemen kaydedilir.
@MainActor
@Observable
public final class BackgroundPreferences {
    public var settings: BackgroundSettings {
        didSet {
            let c = settings.clamped()
            if c != settings { settings = c; return }
            settings.save(to: defaults)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = BackgroundSettings.load(from: defaults)
    }
}
