import CleanerAppCore
import CleanerKit
import AppKit
import SwiftUI

@main
struct CleanerApp: App {
    @State private var model: AppModel
    @State private var ui = UIState()
    @State private var perms = PermissionModel(probe: LivePermissionProbe())
    @State private var prefs: BackgroundPreferences
    @State private var monitor: BackgroundMonitor
    @State private var login: LoginItemModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Dataless (yalnız bulutta duran) dosyalar bu süreçte okunarak indirilemez.
        CloudGuard.disableDatalessMaterializationForProcess()
        _model = State(initialValue: AppModel(scanService: LiveScanService(), trashService: LiveTrashService()))
        let prefs = BackgroundPreferences()
        let monitor = BackgroundMonitor(prefs: prefs, notifier: LiveNotifier(), weeklyScan: LightScanService())
        let login = LoginItemModel(controller: LiveLoginItem(), prefs: prefs)
        _prefs = State(initialValue: prefs)
        _monitor = State(initialValue: monitor)
        _login = State(initialValue: login)
        var snapshotMode = false
        #if DEBUG
        snapshotMode = CommandLine.arguments.contains("--snapshot")
        #endif
        if !snapshotMode {
            login.bootstrap()
            monitor.start()
            // Uyku sonrası hemen bir örnek al.
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in await monitor.tick() }
            }
        }
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let dir = CommandLine.arguments[i + 1]
            DispatchQueue.main.async { Task { @MainActor in await SnapshotRunner.run(into: dir); exit(0) } }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup("Cleaner", id: "main") {
            RootView(model: model, ui: ui, perms: perms)
                .safeAreaInset(edge: .top, spacing: 0) { LoginNoticeBar(login: login) }
                .onAppear { if perms.shouldPresentOnLaunch { ui.sheet = .permissions } }
                .frame(minWidth: 760, minHeight: 540)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshDisk()
                    Task { await perms.refresh() }
                }
                .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
                    model.refreshDisk()
                }
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra(isInserted: $prefs.settings.showInMenuBar) {
            MenuBarContent(model: model, monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        Settings {
            SettingsView(prefs: prefs, login: login, monitor: monitor)
        }
    }
}
