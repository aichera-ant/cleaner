import Foundation
import Testing
@testable import CleanerAppCore

final class FakeNotif: NotificationPermissionControlling, @unchecked Sendable {
    var current: NotificationAuth
    var afterRequest: NotificationAuth
    init(_ c: NotificationAuth, afterRequest: NotificationAuth = .authorized) { current = c; self.afterRequest = afterRequest }
    func status() async -> NotificationAuth { current }
    func request() async -> NotificationAuth { if current == .notDetermined { current = afterRequest }; return current }
}

@MainActor
@Suite struct OnboardingTests {
    func defaults() -> UserDefaults {
        let name = "onb-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func decision() {
        #expect(OnboardingFlow.shouldShow(completed: false, legacyPermissionsSeen: false))
        #expect(!OnboardingFlow.shouldShow(completed: true, legacyPermissionsSeen: false))
        #expect(!OnboardingFlow.shouldShow(completed: false, legacyPermissionsSeen: true))
        #expect(!OnboardingFlow.shouldShow(completed: true, legacyPermissionsSeen: true))
    }

    @Test func shownOnceThenNot() {
        let d = defaults()
        #expect(OnboardingFlow.shouldShow(defaults: d))
        let m = OnboardingModel(defaults: d)
        #expect(m.page == .intro && !m.isFinished)
        m.next()
        #expect(m.page == .permissions)
        m.next() // son sayfadan öteye geçmez
        #expect(m.page == .permissions)
        m.finish()
        #expect(m.isFinished)
        #expect(!OnboardingFlow.shouldShow(defaults: d))
    }

    @Test func skipAlsoCompletes() {
        let d = defaults()
        let m = OnboardingModel(page: .permissions, defaults: d)
        m.back()
        #expect(m.page == .intro)
        m.finish() // "Şimdilik geç" de aynı bayrağı koyar
        #expect(!OnboardingFlow.shouldShow(defaults: d))
    }

    @Test func legacyUserSkips() {
        let d = defaults()
        d.set(true, forKey: PermissionModel.seenKey)
        #expect(!OnboardingFlow.shouldShow(defaults: d))
    }

    @Test func notificationStatusMapping() async {
        #expect(NotificationAuth.authorized.permissionStatus == .granted)
        #expect(NotificationAuth.denied.permissionStatus == .required)
        #expect(NotificationAuth.notDetermined.permissionStatus == .unverified("Henüz sorulmadı"))
        let m = NotificationPermissionModel(controller: FakeNotif(.notDetermined))
        await m.refresh()
        #expect(m.canRequest)
        await m.request()
        #expect(m.auth == .authorized && !m.canRequest)
        let n = NotificationPermissionModel(controller: FakeNotif(.notDetermined, afterRequest: .denied))
        await n.request()
        #expect(n.auth == .denied && !n.canRequest)
    }
}
