import Foundation
import Observation
import ServiceManagement

public enum LoginItemStatus: Sendable, Equatable {
    case enabled
    case notRegistered
    /// Kayıtlı ama kullanıcı Sistem Ayarları'nda onaylamalı.
    case requiresApproval
    case notFound
}

public protocol LoginItemControlling: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// Gerçek: `SMAppService.mainApp`.
public struct LiveLoginItem: LoginItemControlling {
    public init() {}
    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notRegistered
        }
    }
    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Oturum açılışında başlatma: ilk açılışta bir kez kaydeder (varsayılan açık) ve bildirir; Ayarlar'dan değişir.
@MainActor
@Observable
public final class LoginItemModel {
    static let initializedKey = "bg.loginItem.initialized"

    public private(set) var status: LoginItemStatus
    /// Hata ya da onay bekleyen durum için Ayarlar'da gösterilecek sade metin.
    public private(set) var message: String?
    /// İlk açılışta kayıt yapıldıysa pencerede bir kez gösterilir.
    public private(set) var showFirstRunNotice = false

    private let controller: any LoginItemControlling
    private let prefs: BackgroundPreferences
    private let defaults: UserDefaults

    public init(controller: any LoginItemControlling, prefs: BackgroundPreferences, defaults: UserDefaults = .standard) {
        self.controller = controller
        self.prefs = prefs
        self.defaults = defaults
        self.status = controller.status
    }

    /// Uygulama açılırken: ilk kez ise ve ayar açıksa kaydeder; sonra durumu ayara eşler.
    public func bootstrap() {
        if !defaults.bool(forKey: Self.initializedKey) {
            defaults.set(true, forKey: Self.initializedKey)
            if prefs.settings.launchAtLogin {
                if apply(enabled: true) { showFirstRunNotice = true }
            }
        }
        refresh()
    }

    public func dismissNotice() { showFirstRunNotice = false }

    /// Ayarlar anahtarı değişince. Başarısızsa anahtar gerçek duruma döner.
    public func setEnabled(_ on: Bool) {
        _ = apply(enabled: on)
        refresh()
        let actual = status == .enabled || status == .requiresApproval
        if prefs.settings.launchAtLogin != actual { prefs.settings.launchAtLogin = actual }
    }

    /// Sistem Ayarları'ndan değişmiş olabilir.
    public func refresh() {
        status = controller.status
        if status == .requiresApproval {
            message = "Sistem Ayarları > Genel > Açılış Öğeleri'nde Cleaner'a izin vermen gerekiyor."
        } else if message?.hasPrefix("Sistem Ayarları") == true {
            message = nil
        }
    }

    @discardableResult
    private func apply(enabled: Bool) -> Bool {
        do {
            if enabled {
                if controller.status != .enabled { try controller.register() }
            } else if controller.status == .enabled || controller.status == .requiresApproval {
                try controller.unregister()
            }
            message = nil
            return true
        } catch {
            message = "Oturum açılışında başlatma ayarlanamadı: \(error.localizedDescription)"
            return false
        }
    }
}
