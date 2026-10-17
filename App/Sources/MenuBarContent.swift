import AppKit
import CleanerAppCore
import CleanerKit
import SwiftUI

/// Menü çubuğu menüsü: boş alan, son tarama özeti ve kısayollar.
struct MenuBarContent: View {
    let model: AppModel
    let monitor: BackgroundMonitor
    let updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let window = MenuSummary.windowSummary(items: model.items, scannedAt: model.snapshot?.scannedAt, outdated: model.resultsOutdated)
        let latest = MenuSummary.latest(window: window, background: monitor.weeklySummary)
        Text(MenuSummary.diskLine(monitor.disk))
        Text(MenuSummary.scanLine(latest, now: Date()))
        Divider()
        Button("Hepp Cleaner'ı aç") { WindowOpener.showMain(openWindow: openWindow) }
        Button("Şimdi tara") {
            WindowOpener.showMain(openWindow: openWindow)
            Task { await model.startScan() }
        }
        .disabled(model.phase == .scanning || model.phase == .moving)
        SettingsLink { Text("Ayarlar…") }
            .keyboardShortcut(",")
        Button("Güncellemeleri denetle…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        Divider()
        Button("Hepp Cleaner'dan çık") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Menü çubuğu etiketi: simge ve kısa boş alan ("48 GB").
struct MenuBarLabel: View {
    let monitor: BackgroundMonitor
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "internaldrive")
            Text(monitor.menuTitle)
        }
    }
}

/// Ana pencereyi öne getirir; yoksa açar.
@MainActor
enum WindowOpener {
    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && !($0 is NSPanel) }
    }

    static func showMain(openWindow: OpenWindowAction? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = mainWindow() {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else if let openWindow {
            openWindow(id: "main")
        } else {
            // Bildirimden: uygulamayı "yeniden aç" olayıyla pencere açtır.
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
