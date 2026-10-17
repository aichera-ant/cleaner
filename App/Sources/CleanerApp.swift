import CleanerAppCore
import CleanerKit
import SwiftUI

@main
struct CleanerApp: App {
    @State private var model: AppModel
    @State private var ui = UIState()

    init() {
        // Dataless (yalnız bulutta duran) dosyalar bu süreçte okunarak indirilemez.
        CloudGuard.disableDatalessMaterializationForProcess()
        _model = State(initialValue: AppModel(scanService: LiveScanService(), trashService: LiveTrashService()))
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let dir = CommandLine.arguments[i + 1]
            DispatchQueue.main.async { Task { @MainActor in await SnapshotRunner.run(into: dir); exit(0) } }
        }
    }

    var body: some Scene {
        WindowGroup("Cleaner") {
            RootView(model: model, ui: ui)
                .frame(minWidth: 760, minHeight: 540)
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.hiddenTitleBar)
    }
}
