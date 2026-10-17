import Foundation
import Observation
import UserNotifications

/// İlk açılış akışı: tanıtım sayfası, sonra izin sayfası. Bir kez gösterilir.
public enum OnboardingPage: Int, Sendable, CaseIterable {
    case intro
    case permissions
}

/// Akışın gösterilip gösterilmeyeceğine karar verir.
public enum OnboardingFlow {
    public static let completedKey = "onboardingCompleted"

    /// Akış gösterilsin mi. Tamamlandıysa hayır. Eski sürümden güncelleyen kullanıcı (izin ekranını zaten görmüş)
    /// tanıtımı yeniden görmez.
    public static func shouldShow(completed: Bool, legacyPermissionsSeen: Bool) -> Bool {
        !completed && !legacyPermissionsSeen
    }

    public static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        shouldShow(completed: defaults.bool(forKey: completedKey),
                   legacyPermissionsSeen: defaults.bool(forKey: PermissionModel.seenKey))
    }
}

@MainActor
@Observable
public final class OnboardingModel {
    public private(set) var page: OnboardingPage
    public private(set) var isFinished = false
    @ObservationIgnored private let defaults: UserDefaults

    public init(page: OnboardingPage = .intro, defaults: UserDefaults = .standard) {
        self.page = page
        self.defaults = defaults
    }

    /// "Devam": tanıtımdan izin sayfasına.
    public func next() {
        if let n = OnboardingPage(rawValue: page.rawValue + 1) { page = n }
    }

    public func back() {
        if let p = OnboardingPage(rawValue: page.rawValue - 1) { page = p }
    }

    /// "Başla" ya da "Şimdilik geç": bayrağı koyar; akış bir daha gösterilmez.
    public func finish() {
        defaults.set(true, forKey: OnboardingFlow.completedKey)
        isFinished = true
    }
}

/// Bildirim izninin sade durumu.
public enum NotificationAuth: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied

    public var permissionStatus: PermissionStatus {
        switch self {
        case .authorized: .granted
        case .denied: .required
        case .notDetermined: .unverified("Henüz sorulmadı")
        }
    }
}

public protocol NotificationPermissionControlling: Sendable {
    func status() async -> NotificationAuth
    /// macOS iznini sordurur (yalnız henüz sorulmadıysa pencere çıkar).
    func request() async -> NotificationAuth
}

public struct LiveNotificationPermission: NotificationPermissionControlling {
    public init() {}

    private static func map(_ s: UNAuthorizationStatus) -> NotificationAuth {
        switch s {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        default: .notDetermined
        }
    }

    public func status() async -> NotificationAuth {
        Self.map(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }

    public func request() async -> NotificationAuth {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return Self.map(await center.notificationSettings().authorizationStatus)
    }
}

@MainActor
@Observable
public final class NotificationPermissionModel {
    public private(set) var auth: NotificationAuth = .notDetermined
    @ObservationIgnored private let controller: any NotificationPermissionControlling

    public init(controller: any NotificationPermissionControlling = LiveNotificationPermission()) {
        self.controller = controller
    }

    public func refresh() async { auth = await controller.status() }

    public func request() async { auth = await controller.request() }

    /// İstenebilir mi (macOS yalnız bir kez sorar; reddedildiyse Sistem Ayarları gerekir).
    public var canRequest: Bool { auth == .notDetermined }

    public static let settingsURL = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
}
