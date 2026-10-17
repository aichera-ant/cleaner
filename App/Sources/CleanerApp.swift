import CleanerAppCore
import CleanerKit
import AppKit
import SwiftUI

@main
struct CleanerApp: App {
    @State private var model: AppModel
    @State private var ui = UIState()
    @State private var perms = PermissionModel(probe: LivePermissionProbe())

    init() {
        // Dataless (yalnız bulutta duran) dosyalar bu süreçte okunarak indirilemez.
        CloudGuard.disableDatalessMaterializationForProcess()
        _model = State(initialValue: AppModel(scanService: LiveScanService(), trashService: LiveTrashService()))
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let dir = CommandLine.arguments[i + 1]
            DispatchQueue.main.async { Task { @MainActor in await SnapshotRunner.run(into: dir); exit(0) } }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup("Cleaner") {
            RootView(model: model, ui: ui, perms: perms)
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
    }
}
