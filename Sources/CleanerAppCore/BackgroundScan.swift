import CleanerKit
import Foundation
import UserNotifications

/// Haftalık arka plan taraması: yalnız izin listesindeki hafif tarayıcılar (önbellekler, Xcode, eski sürümler,
/// Docker). Proje artıkları, klasörler, uygulamalar, mükerrer ve büyük/eski dosya çalışmaz.
public struct LightScanService: ScanService {
    public static let allowedScannerIDs: Set<String> = ["rules", "xcode", "oldVersions", "docker"]

    public init() {}

    public static func lightRegistry() -> CleanerRegistry {
        var r = CleanerRegistry()
        for c in CleanerRegistry.makeDefault().cleaners where allowedScannerIDs.contains(c.id) { r.register(c) }
        return r
    }

    public func scan(progress: (@Sendable (AppScanProgress) -> Void)?) async throws -> ScanSnapshot {
        CloudGuard.disableDatalessMaterializationForProcess()
        let context = try ScanContext.live()
        let registry = Self.lightRegistry()
        let task = Task(priority: .utility) {
            try await ScanEngine(registry: registry).scan(context)
        }
        let report = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
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
