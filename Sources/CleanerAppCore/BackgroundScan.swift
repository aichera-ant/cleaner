import CleanerKit
import Foundation
import UserNotifications

/// Haftalık arka plan taraması: yalnız okuma yapan hafif tarayıcılar. Ağır olanlar (mükerrer, büyük/eski dosya) yok.
public struct LightScanService: ScanService {
    public static let excludedScannerIDs: Set<String> = ["duplicates", "largeOld"]

    public init() {}

    public static func lightRegistry() -> CleanerRegistry {
        var r = CleanerRegistry()
        for c in CleanerRegistry.makeDefault().cleaners where !excludedScannerIDs.contains(c.id) { r.register(c) }
        return r
    }

    public func scan(progress: (@Sendable (AppScanProgress) -> Void)?) async throws -> ScanSnapshot {
        CloudGuard.disableDatalessMaterializationForProcess()
        let context = try ScanContext.live()
        let report = try await ScanEngine(registry: Self.lightRegistry()).scan(context)
        return ScanSnapshot(items: report.items, errors: report.errors, dropped: report.dropped, scannedAt: context.now)
    }
}

/// Gerçek bildirim gönderici. İzin ilk ihtiyaçta (ilk uyarı) istenir; reddedilirse sessizce vazgeçilir.
public struct LiveNotifier: AlertNotifier {
    public init() {}

    public func deliver(_ alert: NotificationAlert) async -> NotifyResult {
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            settings = await center.notificationSettings()
        }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default: return .denied
        }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.userInfo = ["kind": alert.kind.rawValue]
        let request = UNNotificationRequest(identifier: "cleaner.\(alert.kind.rawValue)", content: content, trigger: nil)
        do {
            try await center.add(request)
            return .delivered
        } catch {
            return .failed
        }
    }
}
