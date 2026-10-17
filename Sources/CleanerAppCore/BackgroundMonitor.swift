import CleanerKit
import Foundation
import Observation

public enum NotifyResult: Sendable, Equatable { case delivered, denied, failed }

/// Bildirim gönderimi. Gerçeği `UserNotifications` kullanır; izin ilk gönderimde istenir.
public protocol AlertNotifier: Sendable {
    func deliver(_ alert: NotificationAlert) async -> NotifyResult
}

/// Arka planda yapılan son taramanın özeti (menüde gösterilir).
public struct ScanSummary: Sendable, Equatable {
    public var date: Date
    public var cleanableBytes: UInt64
    public init(date: Date, cleanableBytes: UInt64) {
        self.date = date
        self.cleanableBytes = cleanableBytes
    }
}

/// Boş alanı belli aralıkla örnekler, uyarı kararlarını `AlertEngine`e sorar, bildirimi gönderir ve haftada bir
/// hafif tarama yapar. Saat, disk okuması, tarama ve bildirim enjekte edilir.
@MainActor
@Observable
public final class BackgroundMonitor {
    public static let sampleInterval: TimeInterval = 300
    static let stateKey = "bg.alertState"

    public private(set) var disk: DiskInfo?
    public private(set) var weeklySummary: ScanSummary?
    /// Son gönderimde bildirim izni reddedilmişti.
    public private(set) var notificationsDenied = false
    public private(set) var history = DiskHistory()
    public private(set) var state: AlertState

    private let prefs: BackgroundPreferences
    private let notifier: any AlertNotifier
    private let weeklyScan: any ScanService
    private let diskProvider: @Sendable () -> DiskInfo?
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let defaults: UserDefaults
    @ObservationIgnored private var ticking = false
    @ObservationIgnored private var weeklyTask: Task<Void, Never>?
    @ObservationIgnored private var scheduler: NSBackgroundActivityScheduler?
    @ObservationIgnored private var labelTimer: Timer?

    public init(prefs: BackgroundPreferences, notifier: any AlertNotifier, weeklyScan: any ScanService,
                diskProvider: @escaping @Sendable () -> DiskInfo? = { DiskInfo.current() },
                now: @escaping @Sendable () -> Date = { Date() },
                calendar: Calendar = .current, defaults: UserDefaults = .standard) {
        self.prefs = prefs
        self.notifier = notifier
        self.weeklyScan = weeklyScan
        self.diskProvider = diskProvider
        self.now = now
        self.calendar = calendar
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.stateKey), let s = try? JSONDecoder().decode(AlertState.self, from: data) {
            state = s
        } else {
            state = AlertState()
        }
        disk = diskProvider()
    }

    /// Menü çubuğu etiketi.
    public var menuTitle: String { disk.map { Fmt.shortBytes($0.availableBytes) } ?? "Hepp Cleaner" }

    // MARK: Zamanlama

    /// Enerji dostu zamanlama: sistem uygun anlarda çalıştırır (5 dk ± 2 dk). Etiket için ayrıca ucuz, esnek bir
    /// dakikalık yenileme vardır; yalnız boş alanı okur, geçmişe ve uyarıya karışmaz.
    public func start() {
        guard scheduler == nil else { return }
        let s = NSBackgroundActivityScheduler(identifier: "com.aichera.cleaner.disk-sample")
        s.repeats = true
        s.interval = Self.sampleInterval
        s.tolerance = 120
        s.qualityOfService = .utility
        s.schedule { [weak self] completion in
            let done = UnsafeSendable(completion)
            Task { @MainActor [weak self] in
                await self?.tick(awaitWeekly: false)
                done.value(.finished)
            }
        }
        scheduler = s
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshLabel() }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        labelTimer = t
        Task { await tick(awaitWeekly: false) }
    }

    public func stop() {
        weeklyTask?.cancel()
        scheduler?.invalidate()
        scheduler = nil
        labelTimer?.invalidate()
        labelTimer = nil
    }

    public func refreshLabel() { disk = diskProvider() }

    // MARK: Örnekleme

    /// Bir örnek alır, uyarıları değerlendirir, gerekirse haftalık taramayı başlatır. Tarama ayrı görevde,
    /// düşük öncelikle çalışır; örnekleme ve uyarılar onu (ya da bildirim iznini) beklemez. `awaitWeekly` true ise
    /// süren haftalık görev bitene kadar beklenir (testler için).
    public func tick(awaitWeekly: Bool = true) async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        let date = now()
        guard let d = diskProvider() else { return }
        disk = d
        let sample = DiskSample(date: date, availableBytes: d.availableBytes, totalBytes: d.totalBytes)
        history.add(sample, now: date)
        let decision = AlertEngine.evaluateDisk(sample: sample, history: history, settings: prefs.settings,
                                                state: state, now: date, calendar: calendar)
        setState(decision.state)
        for alert in decision.alerts { await send(alert) }
        weeklyIfDue(date)
        if awaitWeekly { await waitForWeekly() }
    }

    /// Süren haftalık tarama görevi bitene kadar bekler.
    public func waitForWeekly() async { await weeklyTask?.value }

    private func weeklyIfDue(_ date: Date) {
        // Aynı anda tek tarama.
        guard weeklyTask == nil else { return }
        switch AlertEngine.weeklyAction(settings: prefs.settings, state: state, now: date) {
        case .wait: return
        case .schedule:
            var s = state
            s.weeklyLast = date
            s.weeklyAttempt = nil
            setState(s)
        case .run:
            var s = state
            s.weeklyAttempt = date
            setState(s)
            weeklyTask = Task(priority: .utility) { [weak self] in
                await self?.runWeekly()
                self?.weeklyTask = nil
            }
        }
    }

    private func runWeekly() async {
            do {
                let snap = try await weeklyScan.scan(progress: nil)
                if Task.isCancelled { return }
                let bytes = Summaries.cleanableBytes(snap.items, selection: SelectionState(defaultsFrom: snap.items))
                weeklySummary = ScanSummary(date: snap.scannedAt, cleanableBytes: bytes)
                var done = state
                done.weeklyLast = now()
                done.weeklyAttempt = nil
                setState(done)
                // Ayar tarama sürerken kapatılmış olabilir.
                if prefs.settings.weeklyEnabled, let alert = AlertEngine.weeklyAlert(cleanableBytes: bytes, settings: prefs.settings) {
                    await send(alert)
                }
            } catch {
                // Başarısız ya da iptal: weeklyAttempt kalır, 6 saat sonra yeniden denenir.
            }
    }

    private func send(_ alert: NotificationAlert) async {
        let r = await notifier.deliver(alert)
        notificationsDenied = (r == .denied)
    }

    private func setState(_ s: AlertState) {
        state = s
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.stateKey) }
    }
}

/// Sistemin Sendable olmayan tamamlama kapanışını tek seferlik taşımak için.
private struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}
