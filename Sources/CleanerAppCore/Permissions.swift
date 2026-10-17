import Foundation
import Observation

/// Cleaner'ın isteyebileceği üç macOS izni. Hiçbiri zorunlu değil.
public enum PermissionKind: String, CaseIterable, Sendable, Identifiable {
    case fullDiskAccess
    case appManagement
    case automation

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fullDiskAccess: "Tam Disk Erişimi"
        case .appManagement: "Uygulama Yönetimi"
        case .automation: "Finder'ı denetleme"
        }
    }

    /// Sade Türkçe tek cümle: izin neden gerekli.
    public var reason: String {
        switch self {
        case .fullDiskAccess: "Başka uygulamaların artık ve önbellek klasörlerine bakabilmek için."
        case .appManagement: "Uygulamaları Çöp Kutusu'na taşıyabilmek için."
        case .automation: "Parola ya da Touch ID isteyen korunan uygulamaları Finder aracılığıyla taşıyabilmek için."
        }
    }

    /// Verilmezse ne olur.
    public var withoutIt: String {
        switch self {
        case .fullDiskAccess: "İzinsiz de çalışır; korumalı klasörlerdeki artıklar taranamaz."
        case .appManagement: "İzinsiz de çalışır; uygulamalar kaldırılamayabilir."
        case .automation: "İzinsiz de çalışır; korunan uygulamalar taşınamaz."
        }
    }

    public var settingsURL: String {
        switch self {
        case .fullDiskAccess: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .appManagement: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"
        case .automation: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        }
    }
}

/// Tespit sonucu (ham).
public enum ProbeResult: Sendable, Equatable {
    case granted
    case denied
    /// macOS henüz sormadı.
    case notDetermined
    /// Tespit edilemiyor ya da hata.
    case unknown
}

/// Ekranda görünen durum.
public enum PermissionStatus: Sendable, Equatable {
    case granted
    /// Turuncu: verilmeli.
    case required
    /// Gri: doğrulanamıyor / henüz sorulmadı.
    case unverified(String)

    public var label: String {
        switch self {
        case .granted: "Verildi"
        case .required: "Gerekli"
        case .unverified(let s): s
        }
    }

    public var isMissing: Bool { self == .required }
}

/// Canlı tespit protokolün arkasında; testte sahtesi verilir. İçerik okunmaz, başka uygulama değiştirilmez.
public protocol PermissionProbe: Sendable {
    func fullDiskAccess() -> ProbeResult
    /// `askUser: true` kullanıcıya macOS iznini sordurabilir; arka plan kuyruğunda çağrılmalı.
    func automation(askUser: Bool) -> ProbeResult
}

@MainActor
@Observable
public final class PermissionModel {
    public static let seenKey = "permissionsSeen"
    public static let appManagementKey = "appManagementMarked"

    public private(set) var fullDisk: ProbeResult = .unknown
    public private(set) var automation: ProbeResult = .unknown
    public private(set) var appManagementMarked: Bool

    @ObservationIgnored private let probe: any PermissionProbe
    @ObservationIgnored private let defaults: UserDefaults

    public init(probe: any PermissionProbe, defaults: UserDefaults = .standard) {
        self.probe = probe
        self.defaults = defaults
        self.appManagementMarked = defaults.bool(forKey: Self.appManagementKey)
        // Açılışta bir kez eşzamanlı (açılış ekranı kararı bu değerlere bakar). Sonraki yenilemeler arka planda.
        apply(Self.probeAll(probe))
    }

    // MARK: Durum eşlemesi

    public func status(_ kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .fullDiskAccess:
            switch fullDisk {
            case .granted: .granted
            case .denied: .required
            case .notDetermined, .unknown: .unverified("Doğrulanamıyor")
            }
        case .appManagement:
            appManagementMarked ? .granted : .unverified("Doğrulanamıyor")
        case .automation:
            switch automation {
            case .granted: .granted
            case .denied: .required
            case .notDetermined: .unverified("Henüz sorulmadı")
            case .unknown: .unverified("Doğrulanamıyor")
            }
        }
    }

    /// Eksik (turuncu) izin var mı. Kenar çubuğundaki nokta bunu gösterir.
    public var hasMissing: Bool { PermissionKind.allCases.contains { status($0).isMissing } }

    // MARK: Gösterim

    public var seen: Bool { defaults.bool(forKey: Self.seenKey) }

    /// Açılışta ekran gösterilsin mi: ilk açılış ya da Tam Disk Erişimi/Otomasyon reddedilmiş.
    public var shouldPresentOnLaunch: Bool {
        !seen || fullDisk == .denied || automation == .denied
    }

    /// "Devam et": ilk açılış bayrağını koyar.
    public func markSeen() { defaults.set(true, forKey: Self.seenKey) }

    // MARK: Yenileme

    /// Son başlatılan sorgunun sırası: geç dönen eski sorgu yenisinin sonucunu ezmez.
    @ObservationIgnored private var generation = 0

    nonisolated private static func probeAll(_ probe: any PermissionProbe) -> (ProbeResult, ProbeResult) {
        (probe.fullDiskAccess(), probe.automation(askUser: false))
    }

    private func apply(_ r: (ProbeResult, ProbeResult)) {
        fullDisk = r.0
        automation = r.1
    }

    /// Kullanıcıya sormaz. Uygulama öne gelince çağrılır. Sorgular (TCC, Apple Event izni) ana iş parçacığını
    /// bekletmesin diye arka planda yapılır; sonuç MainActor'da uygulanır.
    public func refresh() async {
        generation += 1
        let mine = generation
        let probe = self.probe
        let r = await Task.detached(priority: .utility) { Self.probeAll(probe) }.value
        guard mine == generation else { return }
        apply(r)
    }

    /// "Şimdi izin iste": macOS sorabilir; arka plan kuyruğunda çalışır.
    public func requestAutomation() async {
        generation += 1 // süren yenileme bu sonucu ezmesin
        let probe = self.probe
        let r = await Task.detached(priority: .userInitiated) { probe.automation(askUser: true) }.value
        automation = r
    }

    // MARK: Uygulama Yönetimi işareti

    public func setAppManagementMarked(_ on: Bool) {
        appManagementMarked = on
        defaults.set(on, forKey: Self.appManagementKey)
    }

    /// Taşıma sonucundaki retleri inceler. Uygulama Yönetimi kaynaklı ret varsa işareti kaldırır;
    /// true dönerse ekranın yeniden önerilmesi gerekir.
    @discardableResult
    public func noteRefusals(_ refusals: [(reason: String, path: String)]) -> Bool {
        guard refusals.contains(where: { Self.isAppManagementDenial(reason: $0.reason, path: $0.path) }) else { return false }
        setAppManagementMarked(false)
        return true
    }

    /// Ret nedeni "Uygulama Yönetimi" diyorsa ya da uygulama paketinde izin hatası (EPERM) ise.
    public nonisolated static func isAppManagementDenial(reason: String, path: String) -> Bool {
        let r = reason.lowercased()
        if r.contains("uygulama yönetimi") || r.contains("app management") { return true }
        let eperm = r.contains("eperm") || r.contains("operation not permitted") || r.contains("izin verilmedi") || r.contains("izin yok")
        return eperm && path.lowercased().hasSuffix(".app")
    }
}
