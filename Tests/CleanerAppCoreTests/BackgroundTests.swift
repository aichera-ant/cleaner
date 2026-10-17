import CleanerKit
import Foundation
import Testing
@testable import CleanerAppCore

private let GB: UInt64 = 1_000_000_000

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

/// 2030-01-01 00:00 UTC + saat.
private func at(hours: Double) -> Date { Date(timeIntervalSince1970: 1_893_456_000 + hours * 3600) }

/// Karar motorunu adım adım süren yardımcı (saat ve disk enjekte).
struct Sim {
    var settings = BackgroundSettings()
    var history = DiskHistory()
    var state = AlertState()
    var total: UInt64 = 500 * GB

    mutating func step(hours: Double, availableGB: Double) -> [NotificationAlert.Kind] {
        let now = at(hours: hours)
        let s = DiskSample(date: now, availableBytes: UInt64(availableGB * Double(GB)), totalBytes: total)
        history.add(s, now: now)
        let d = AlertEngine.evaluateDisk(sample: s, history: history, settings: settings, state: state, now: now, calendar: utc)
        state = d.state
        return d.alerts.map(\.kind)
    }
}

@Suite struct LowSpaceTests {
    @Test("eşik: GB ve yüzdeden büyüğü")
    func threshold() {
        let s = BackgroundSettings()
        #expect(AlertEngine.lowThreshold(total: 128 * GB, settings: s) == 20 * GB)
        #expect(AlertEngine.lowThreshold(total: 1000 * GB, settings: s) == 100 * GB)
    }

    @Test("sınır: tam eşikte uyarı yok, bir bayt altında var")
    func boundary() {
        var sim = Sim()
        sim.total = 100 * GB // eşik 20 GB
        #expect(sim.step(hours: 1, availableGB: 20) == [])
        #expect(sim.step(hours: 2, availableGB: 19.999999999) == [.lowSpace])
    }

    @Test("günde en fazla bir kez; ertesi gün hâlâ düşükse yeniden")
    func oncePerDay() {
        var sim = Sim()
        sim.total = 500 * GB // eşik 50 GB
        #expect(sim.step(hours: 1, availableGB: 40) == [.lowSpace])
        #expect(sim.step(hours: 2, availableGB: 39) == [])
        #expect(sim.step(hours: 23.9, availableGB: 38) == [])
        #expect(sim.step(hours: 24.1, availableGB: 38) == [.lowSpace])
    }

    @Test("eşiğin üstüne çıkıp tekrar düşünce aynı gün yeniden uyarır")
    func recoverThenDrop() {
        var sim = Sim()
        sim.settings.rapidDropEnabled = false
        #expect(sim.step(hours: 1, availableGB: 40) == [.lowSpace])
        #expect(sim.step(hours: 2, availableGB: 70) == [])
        #expect(sim.step(hours: 3, availableGB: 45) == [.lowSpace])
        #expect(sim.step(hours: 4, availableGB: 44) == [])
    }

    @Test("eşiğe çok yakın dalgalanma yeniden uyarı sayılmaz (pay)")
    func hysteresis() {
        var sim = Sim()
        #expect(sim.step(hours: 1, availableGB: 49) == [.lowSpace])
        #expect(sim.step(hours: 2, availableGB: 51) == []) // eşik 50, pay 5 GB: 55 altı
        #expect(sim.step(hours: 3, availableGB: 49) == [])
        #expect(sim.step(hours: 4, availableGB: 56) == [])
        #expect(sim.step(hours: 5, availableGB: 49) == [.lowSpace])
    }

    @Test("ayar kapalı: uyarı yok ve günlük hak harcanmaz")
    func disabled() {
        var sim = Sim()
        sim.settings.lowSpaceEnabled = false
        #expect(sim.step(hours: 1, availableGB: 10) == [])
        sim.settings.lowSpaceEnabled = true
        #expect(sim.step(hours: 2, availableGB: 10) == [.lowSpace])
    }

    @Test("özel eşik uygulanır")
    func custom() {
        var sim = Sim()
        sim.settings.lowSpaceGB = 100
        sim.settings.lowSpacePercent = 1
        #expect(sim.step(hours: 1, availableGB: 90) == [.lowSpace])
    }

    @Test("saat geriye atlarsa çökmez; farklı gün sayılıp uyarır, aynı güne dönünce susar")
    func clockBack() {
        var sim = Sim()
        #expect(sim.step(hours: 50, availableGB: 10) == [.lowSpace])
        #expect(sim.step(hours: 2, availableGB: 10) == [.lowSpace]) // gün farklı
        #expect(sim.step(hours: 3, availableGB: 10) == [])
    }
}

@Suite struct RapidDropTests {
    @Test("1 saatte 10 GB düşüş: sınırda uyarır, altında uyarmaz")
    func boundary() {
        var a = Sim()
        _ = a.step(hours: 0, availableGB: 100)
        #expect(a.step(hours: 0.5, availableGB: 90.0001) == [])
        var b = Sim()
        _ = b.step(hours: 0, availableGB: 100)
        #expect(b.step(hours: 0.5, availableGB: 90) == [.rapidDrop])
    }

    @Test("aynı olay için tekrar etmez; düşüş bitince yeni olay yeniden uyarır")
    func noRepeat() {
        var sim = Sim()
        sim.settings.lowSpaceEnabled = false
        _ = sim.step(hours: 0, availableGB: 200)
        #expect(sim.step(hours: 0.25, availableGB: 180) == [.rapidDrop])
        #expect(sim.step(hours: 0.5, availableGB: 170) == [])
        #expect(sim.step(hours: 0.75, availableGB: 150) == [])
        // Tepe noktası pencereden çıkınca olay biter.
        #expect(sim.step(hours: 2, availableGB: 150) == [])
        #expect(sim.state.rapidActive == false)
        #expect(sim.step(hours: 2.25, availableGB: 130) == [.rapidDrop])
    }

    @Test("düşüş 1 saatten uzun sürede yayılırsa uyarmaz")
    func slow() {
        var sim = Sim()
        sim.settings.lowSpaceEnabled = false
        _ = sim.step(hours: 0, availableGB: 200)
        _ = sim.step(hours: 0.9, availableGB: 195)
        #expect(sim.step(hours: 1.5, availableGB: 188) == []) // pencere: 0.9'dan bu yana 7 GB
    }

    @Test("uzun uykudan sonra tek örnek: düşüş sayılmaz")
    func sleepGap() {
        var sim = Sim()
        sim.settings.lowSpaceEnabled = false
        _ = sim.step(hours: 0, availableGB: 200)
        #expect(sim.step(hours: 9, availableGB: 100) == [])
    }

    @Test("ayar kapalıyken görülen olay açılınca geriye dönük uyarmaz")
    func disabledThenEnabled() {
        var sim = Sim()
        sim.settings.lowSpaceEnabled = false
        sim.settings.rapidDropEnabled = false
        _ = sim.step(hours: 0, availableGB: 200)
        #expect(sim.step(hours: 0.2, availableGB: 180) == [])
        sim.settings.rapidDropEnabled = true
        #expect(sim.step(hours: 0.4, availableGB: 175) == [])
    }

    @Test("saat geriye atlarsa gelecekteki örnekler atılır")
    func clockBack() {
        var sim = Sim()
        sim.settings.lowSpaceEnabled = false
        _ = sim.step(hours: 10, availableGB: 300)
        #expect(sim.step(hours: 5, availableGB: 100) == []) // 300 GB'lık örnek "gelecekte", sayılmaz
        #expect(sim.history.samples.count == 1)
    }

    @Test("özel eşik")
    func custom() {
        var sim = Sim()
        sim.settings.lowSpaceEnabled = false
        sim.settings.rapidDropGB = 3
        _ = sim.step(hours: 0, availableGB: 100)
        #expect(sim.step(hours: 0.1, availableGB: 97) == [.rapidDrop])
    }
}

@Suite struct HistoryTests {
    @Test("geçmiş sınırlı: 24 saatten eski ve 400 üstü atılır")
    func bounded() {
        var h = DiskHistory()
        for i in 0..<500 {
            let now = at(hours: Double(i) * 0.01)
            h.add(DiskSample(date: now, availableBytes: GB, totalBytes: 10 * GB), now: now)
        }
        #expect(h.samples.count == DiskHistory.maxCount)
        var old = DiskHistory()
        old.add(DiskSample(date: at(hours: 0), availableBytes: GB, totalBytes: GB), now: at(hours: 0))
        old.add(DiskSample(date: at(hours: 30), availableBytes: GB, totalBytes: GB), now: at(hours: 30))
        #expect(old.samples.count == 1)
    }
}

@Suite struct WeeklyTests {
    let s = BackgroundSettings()
    let day: TimeInterval = 24 * 3600

    @Test("ilk görülünce zamanla, bir hafta dolmadan bekle, dolunca çalıştır")
    func schedule() {
        var st = AlertState()
        #expect(AlertEngine.weeklyAction(settings: s, state: st, now: at(hours: 0)) == .schedule)
        st.weeklyLast = at(hours: 0)
        #expect(AlertEngine.weeklyAction(settings: s, state: st, now: at(hours: 7 * 24 - 0.01)) == .wait)
        #expect(AlertEngine.weeklyAction(settings: s, state: st, now: at(hours: 7 * 24)) == .run)
    }

    @Test("başarısız denemeden sonra 6 saat bekler")
    func retry() {
        var st = AlertState()
        st.weeklyLast = at(hours: 0)
        st.weeklyAttempt = at(hours: 8 * 24)
        #expect(AlertEngine.weeklyAction(settings: s, state: st, now: at(hours: 8 * 24 + 5)) == .wait)
        #expect(AlertEngine.weeklyAction(settings: s, state: st, now: at(hours: 8 * 24 + 6)) == .run)
    }

    @Test("saat geriye atlarsa sayaç yeniden kurulur; ayar kapalıyken çalışmaz")
    func clockAndDisabled() {
        var st = AlertState()
        st.weeklyLast = at(hours: 100)
        #expect(AlertEngine.weeklyAction(settings: s, state: st, now: at(hours: 10)) == .schedule)
        var off = s
        off.weeklyEnabled = false
        #expect(AlertEngine.weeklyAction(settings: off, state: AlertState(), now: at(hours: 0)) == .wait)
        st.weeklyLast = at(hours: 0)
        #expect(AlertEngine.weeklyAction(settings: off, state: st, now: at(hours: 9 * 24)) == .wait)
    }

    @Test("özet yalnız eşik (1 GB) ve üstünde bildirilir")
    func alertBoundary() {
        #expect(AlertEngine.weeklyAlert(cleanableBytes: GB - 1, settings: s) == nil)
        #expect(AlertEngine.weeklyAlert(cleanableBytes: GB, settings: s)?.kind == .weeklySummary)
    }
}

// MARK: Koordinatör

final class FakeNotifier: AlertNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [NotificationAlert] = []
    var result: NotifyResult = .delivered
    var sent: [NotificationAlert] { lock.lock(); defer { lock.unlock() }; return _sent }
    private func record(_ a: NotificationAlert) { lock.lock(); _sent.append(a); lock.unlock() }
    func deliver(_ alert: NotificationAlert) async -> NotifyResult {
        record(alert)
        return result
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: T
    init(_ v: T) { _v = v }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return _v } set { lock.lock(); _v = newValue; lock.unlock() } }
}

private func freshDefaults() -> UserDefaults {
    let name = "cleaner-test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@MainActor
@Suite struct MonitorTests {
    struct Rig {
        let monitor: BackgroundMonitor
        let notifier: FakeNotifier
        let clock: Box<Date>
        let avail: Box<UInt64>
        let scan: FakeScan
        let prefs: BackgroundPreferences
        let defaults: UserDefaults
    }

    func rig(items: [CleanItem] = [], defaults: UserDefaults = freshDefaults()) -> Rig {
        let clock = Box(at(hours: 0))
        let avail = Box(200 * GB)
        let notifier = FakeNotifier()
        let scan = FakeScan(ScanSnapshot(items: items, scannedAt: at(hours: 0)))
        let prefs = BackgroundPreferences(defaults: defaults)
        let m = BackgroundMonitor(prefs: prefs, notifier: notifier, weeklyScan: scan,
                                  diskProvider: { DiskInfo(totalBytes: 500 * GB, availableBytes: avail.value) },
                                  now: { clock.value }, calendar: utc, defaults: defaults)
        return Rig(monitor: m, notifier: notifier, clock: clock, avail: avail, scan: scan, prefs: prefs, defaults: defaults)
    }

    @Test("eşik altı: bildirim gider, etiket güncellenir, aynı gün tekrar gitmez")
    func lowAlert() async {
        let r = rig()
        r.avail.value = 30 * GB
        await r.monitor.tick()
        #expect(r.notifier.sent.map(\.kind) == [.lowSpace])
        #expect(r.monitor.menuTitle == "30 GB")
        r.clock.value = at(hours: 1)
        await r.monitor.tick()
        #expect(r.notifier.sent.count == 1)
    }

    @Test("durum yeniden başlatmada korunur (günde bir kez kuralı)")
    func statePersists() async {
        let d = freshDefaults()
        let a = rig(defaults: d)
        a.avail.value = 30 * GB
        await a.monitor.tick()
        let b = rig(defaults: d)
        b.avail.value = 30 * GB
        b.clock.value = at(hours: 2)
        await b.monitor.tick()
        #expect(b.notifier.sent.isEmpty)
    }

    @Test("izin reddedildi: bayrak kalkar, çökmez")
    func denied() async {
        let r = rig()
        r.notifier.result = .denied
        r.avail.value = 10 * GB
        await r.monitor.tick()
        #expect(r.monitor.notificationsDenied)
    }

    @Test("haftalık: ilk tick zamanlar, hafta dolunca tarar ve ≥1 GB ise bildirir")
    func weekly() async {
        var big = item("büyük", cat: .caches, bytes: 3 * GB, risk: .green)
        big.preselect = true
        let r = rig(items: [big])
        await r.monitor.tick()
        #expect(r.notifier.sent.isEmpty)
        #expect(r.monitor.weeklySummary == nil)
        r.clock.value = at(hours: 7 * 24 + 1)
        await r.monitor.tick()
        #expect(r.notifier.sent.map(\.kind) == [.weeklySummary])
        #expect(r.monitor.weeklySummary?.cleanableBytes == 3 * GB)
        // Aynı hafta içinde tekrar etmez.
        r.clock.value = at(hours: 8 * 24)
        await r.monitor.tick()
        #expect(r.notifier.sent.count == 1)
    }

    @Test("haftalık: 1 GB altı bildirilmez ama özet menü için tutulur")
    func weeklySmall() async {
        let r = rig(items: [item("küçük", bytes: GB / 2, risk: .green)])
        await r.monitor.tick()
        r.clock.value = at(hours: 7 * 24)
        await r.monitor.tick()
        #expect(r.notifier.sent.isEmpty)
        #expect(r.monitor.weeklySummary != nil)
    }

    @Test("haftalık: ayar kapalıyken taranmaz")
    func weeklyOff() async {
        let r = rig(items: [item("x", bytes: 5 * GB, risk: .green)])
        r.prefs.settings.weeklyEnabled = false
        await r.monitor.tick()
        r.clock.value = at(hours: 30 * 24)
        await r.monitor.tick()
        #expect(r.monitor.weeklySummary == nil)
        #expect(r.notifier.sent.isEmpty)
    }

    @Test("haftalık tarama hatası: bildirim yok, 6 saat sonra yeniden dener")
    func weeklyFailure() async {
        let r = rig(items: [item("x", bytes: 5 * GB, risk: .green)])
        await r.monitor.tick()
        r.scan.error = CancellationError()
        r.clock.value = at(hours: 7 * 24)
        await r.monitor.tick()
        #expect(r.monitor.weeklySummary == nil)
        r.scan.error = nil
        r.clock.value = at(hours: 7 * 24 + 1)
        await r.monitor.tick()
        #expect(r.monitor.weeklySummary == nil) // 6 saat dolmadı
        r.clock.value = at(hours: 7 * 24 + 6)
        await r.monitor.tick()
        #expect(r.monitor.weeklySummary != nil)
    }

    @Test("disk okunamazsa tick sessizce döner")
    func noDisk() async {
        let prefs = BackgroundPreferences(defaults: freshDefaults())
        let n = FakeNotifier()
        let m = BackgroundMonitor(prefs: prefs, notifier: n, weeklyScan: FakeScan(ScanSnapshot(items: [], scannedAt: at(hours: 0))),
                                  diskProvider: { nil }, now: { at(hours: 0) }, calendar: utc, defaults: freshDefaults())
        await m.tick()
        #expect(n.sent.isEmpty)
    }
}

// MARK: Ayarlar

@MainActor
@Suite struct SettingsTests {
    @Test("varsayılanlar")
    func defaultsValues() {
        let s = BackgroundPreferences(defaults: freshDefaults()).settings
        #expect(s.launchAtLogin && s.showInMenuBar)
        #expect(s.lowSpaceEnabled && s.lowSpaceGB == 20 && s.lowSpacePercent == 10)
        #expect(s.rapidDropEnabled && s.rapidDropGB == 10)
        #expect(s.weeklyEnabled && s.weeklyMinGB == 1)
    }

    @Test("kaydedilir ve yeniden okunur; uç değerler sınırlanır")
    func persistAndClamp() {
        let d = freshDefaults()
        let p = BackgroundPreferences(defaults: d)
        p.settings.lowSpaceEnabled = false
        p.settings.lowSpaceGB = 35
        p.settings.rapidDropGB = 0
        p.settings.lowSpacePercent = 99
        let q = BackgroundPreferences(defaults: d)
        #expect(q.settings.lowSpaceEnabled == false)
        #expect(q.settings.lowSpaceGB == 35)
        #expect(q.settings.rapidDropGB == 1)
        #expect(q.settings.lowSpacePercent == 50)
    }

    @Test("kısa boyut biçimi")
    func shortBytes() {
        #expect(Fmt.shortBytes(48 * GB + 400_000_000) == "48 GB")
        #expect(Fmt.shortBytes(4_200_000_000) == "4,2 GB")
        #expect(Fmt.shortBytes(1_250_000_000_000) == "1,3 TB" || Fmt.shortBytes(1_250_000_000_000) == "1,2 TB")
        #expect(Fmt.shortBytes(0) == "0 MB")
    }

    @Test("hafif tarama: ağır tarayıcılar çıkarılmış, diğerleri duruyor")
    func lightRegistry() {
        let ids = Set(LightScanService.lightRegistry().cleaners.map(\.id))
        let all = Set(CleanerRegistry.makeDefault().cleaners.map(\.id))
        #expect(!ids.contains("duplicates") && !ids.contains("largeOld"))
        #expect(all.subtracting(ids) == ["duplicates", "largeOld"])
    }
}

// MARK: Oturum açılışı

final class FakeLogin: LoginItemControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: LoginItemStatus = .notRegistered
    private(set) var registerCalls = 0
    var failRegister = false
    var afterRegister: LoginItemStatus = .enabled
    var status: LoginItemStatus { lock.lock(); defer { lock.unlock() }; return _status }
    func setStatus(_ s: LoginItemStatus) { lock.lock(); _status = s; lock.unlock() }
    func register() throws {
        registerCalls += 1
        if failRegister { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "reddedildi"]) }
        setStatus(afterRegister)
    }
    func unregister() throws { setStatus(.notRegistered) }
}

@MainActor
@Suite struct LoginItemTests {
    func make(_ f: FakeLogin = FakeLogin(), defaults: UserDefaults = freshDefaults()) -> (LoginItemModel, FakeLogin, BackgroundPreferences) {
        let p = BackgroundPreferences(defaults: defaults)
        return (LoginItemModel(controller: f, prefs: p, defaults: defaults), f, p)
    }

    @Test("ilk açılış: kaydeder ve bir kez bildirir; ikinci açılışta tekrar kaydetmez")
    func firstRun() {
        let d = freshDefaults()
        let (m, f, _) = make(defaults: d)
        m.bootstrap()
        #expect(f.registerCalls == 1 && m.status == .enabled && m.showFirstRunNotice)
        m.dismissNotice()
        f.setStatus(.notRegistered) // kullanıcı Sistem Ayarları'ndan kaldırdı
        let (m2, f2, _) = make(f, defaults: d)
        m2.bootstrap()
        #expect(f2.registerCalls == 1 && !m2.showFirstRunNotice && m2.status == .notRegistered)
    }

    @Test("ayar kapalıysa ilk açılışta kaydedilmez")
    func firstRunOff() {
        let d = freshDefaults()
        BackgroundPreferences(defaults: d).settings.launchAtLogin = false
        let (m, f, _) = make(defaults: d)
        m.bootstrap()
        #expect(f.registerCalls == 0 && !m.showFirstRunNotice)
    }

    @Test("kayıt hatası Ayarlar'da gösterilir, anahtar gerçek duruma döner, bildirim yok")
    func failure() {
        let f = FakeLogin()
        f.failRegister = true
        let (m, _, p) = make(f)
        m.bootstrap()
        #expect(m.message?.contains("reddedildi") == true)
        #expect(!m.showFirstRunNotice)
        p.settings.launchAtLogin = true
        m.setEnabled(true)
        #expect(p.settings.launchAtLogin == false)
    }

    @Test("onay bekliyor: açıklama gösterilir, anahtar açık kalır")
    func approval() {
        let f = FakeLogin()
        f.afterRegister = .requiresApproval
        let (m, _, p) = make(f)
        m.bootstrap()
        #expect(m.status == .requiresApproval && m.message?.contains("Açılış Öğeleri") == true)
        #expect(p.settings.launchAtLogin)
    }

    @Test("Ayarlar'dan kapatma kaydı kaldırır")
    func disable() {
        let (m, f, p) = make()
        m.bootstrap()
        p.settings.launchAtLogin = false
        m.setEnabled(false)
        #expect(f.status == .notRegistered && m.status == .notRegistered && p.settings.launchAtLogin == false)
    }
}
