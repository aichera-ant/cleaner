import Foundation
import Testing
@testable import CleanerAppCore

final class FakeProbe: PermissionProbe, @unchecked Sendable {
    var fda: ProbeResult
    var auto: ProbeResult
    var askedAuto: ProbeResult?
    init(fda: ProbeResult = .unknown, auto: ProbeResult = .unknown) { self.fda = fda; self.auto = auto }
    func fullDiskAccess() -> ProbeResult { fda }
    func automation(askUser: Bool) -> ProbeResult { askUser ? (askedAuto ?? auto) : auto }
}

@MainActor
@Suite struct PermissionTests {
    func defaults() -> UserDefaults {
        let name = "perm-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func statusMapping() {
        let m = PermissionModel(probe: FakeProbe(fda: .granted, auto: .notDetermined), defaults: defaults())
        #expect(m.status(.fullDiskAccess) == .granted)
        #expect(m.status(.automation) == .unverified("Henüz sorulmadı"))
        #expect(m.status(.appManagement) == .unverified("Doğrulanamıyor"))
        #expect(!m.hasMissing)
        let n = PermissionModel(probe: FakeProbe(fda: .denied, auto: .denied), defaults: defaults())
        #expect(n.status(.fullDiskAccess) == .required)
        #expect(n.status(.automation) == .required)
        #expect(n.hasMissing)
        let u = PermissionModel(probe: FakeProbe(fda: .unknown, auto: .unknown), defaults: defaults())
        #expect(u.status(.fullDiskAccess) == .unverified("Doğrulanamıyor"))
        #expect(u.status(.automation) == .unverified("Doğrulanamıyor"))
    }

    @Test func firstLaunchPresentsThenNot() {
        let d = defaults()
        let probe = FakeProbe(fda: .granted, auto: .granted)
        let m = PermissionModel(probe: probe, defaults: d)
        #expect(m.shouldPresentOnLaunch)
        m.markSeen()
        #expect(!PermissionModel(probe: probe, defaults: d).shouldPresentOnLaunch)
    }

    @Test func presentsWhenDeniedEvenIfSeen() {
        let d = defaults()
        d.set(true, forKey: PermissionModel.seenKey)
        #expect(PermissionModel(probe: FakeProbe(fda: .denied, auto: .granted), defaults: d).shouldPresentOnLaunch)
        #expect(PermissionModel(probe: FakeProbe(fda: .granted, auto: .denied), defaults: d).shouldPresentOnLaunch)
        #expect(!PermissionModel(probe: FakeProbe(fda: .unknown, auto: .notDetermined), defaults: d).shouldPresentOnLaunch)
    }

    @Test func refreshPicksUpChange() {
        let probe = FakeProbe(fda: .denied, auto: .notDetermined)
        let m = PermissionModel(probe: probe, defaults: defaults())
        #expect(m.status(.fullDiskAccess) == .required)
        probe.fda = .granted
        m.refresh()
        #expect(m.status(.fullDiskAccess) == .granted)
    }

    @Test func requestAutomationUpdates() async {
        let probe = FakeProbe(fda: .granted, auto: .notDetermined)
        probe.askedAuto = .granted
        let m = PermissionModel(probe: probe, defaults: defaults())
        await m.requestAutomation()
        #expect(m.status(.automation) == .granted)
    }

    @Test func appManagementMarkPersistsAndClearsOnDenial() {
        let d = defaults()
        let m = PermissionModel(probe: FakeProbe(), defaults: d)
        m.setAppManagementMarked(true)
        #expect(m.status(.appManagement) == .granted)
        #expect(PermissionModel(probe: FakeProbe(), defaults: d).appManagementMarked)
        // İlgisiz ret işareti kaldırmaz.
        #expect(!m.noteRefusals([(reason: "taşınamadı: dosya yok", path: "/tmp/a")]))
        #expect(m.appManagementMarked)
        // EPERM ama uygulama paketi değil: kalkmaz.
        #expect(!m.noteRefusals([(reason: "taşınamadı: EPERM", path: "/tmp/cache")]))
        #expect(m.appManagementMarked)
        // Uygulama paketinde EPERM: kalkar.
        #expect(m.noteRefusals([(reason: "taşınamadı: Operation not permitted (EPERM)", path: "/Applications/X.app")]))
        #expect(!m.appManagementMarked)
        #expect(!PermissionModel(probe: FakeProbe(), defaults: d).appManagementMarked)
        // Açık neden.
        m.setAppManagementMarked(true)
        #expect(m.noteRefusals([(reason: "Uygulama Yönetimi izni gerekli", path: "")]))
        #expect(!m.appManagementMarked)
    }
}
