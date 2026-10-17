import CleanerAppCore
import CleanerKit
import SwiftUI

struct RootView: View {
    let model: AppModel
    let ui: UIState

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model, ui: ui)
                .frame(width: 224)
            Divider()
            MainPane(model: model, ui: ui)
        }
        .background(Theme.window)
        .overlay { SheetLayer(model: model, ui: ui) }
        .background(WindowConfigurator())
    }
}

struct MainPane: View {
    let model: AppModel
    let ui: UIState

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(model: model, ui: ui)
            Divider()
            content
            if showsActionBar {
                Divider()
                ActionBar(model: model, ui: ui)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var showsActionBar: Bool {
        guard model.phase == .ready, model.snapshot != nil else { return false }
        if ui.section == .overview { return !model.selectedItems.isEmpty }
        return true
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .scanning:
            ScanningView(progress: model.progress)
        case .result:
            ResultView(model: model, ui: ui)
        case .idle where model.snapshot == nil:
            WelcomeView(model: model)
        default:
            if model.snapshot == nil {
                WelcomeView(model: model)
            } else {
                switch ui.section {
                case .overview: OverviewView(model: model, ui: ui)
                case .category(let c): CategoryView(model: model, ui: ui, category: c)
                }
            }
        }
    }
}

struct Toolbar: View {
    let model: AppModel
    let ui: UIState

    private var title: String {
        switch ui.section {
        case .overview: "Özet"
        case .category(let c): CategoryInfo.info(for: c).title
        }
    }

    private var subtitle: String {
        guard let s = model.snapshot, model.phase == .ready else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let t = "Taranma \(f.string(from: s.scannedAt))"
        return model.isStale() ? t + " · eski, yeniden tara" : t
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 14, weight: .bold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.fg2).monospacedDigit()
            Spacer()
            if model.phase == .scanning {
                Button("Vazgeç") { model.cancelScan() }.buttonStyle(SoftButtonStyle())
            } else {
                Button {
                    Task { await model.startScan() }
                } label: {
                    Label(model.snapshot == nil ? "Tara" : "Yeniden tara", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SoftButtonStyle())
                .disabled(model.phase == .moving)
            }
        }
        .padding(.leading, 20).padding(.trailing, 14)
        .frame(height: 52)
    }
}

struct ActionBar: View {
    let model: AppModel
    let ui: UIState

    var body: some View {
        let n = model.selectedItems.count
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text(Fmt.bytes(model.selectedBytes)).font(.system(size: 17, weight: .bold, design: .rounded))
                Text("· \(n) öğe seçili").foregroundStyle(Theme.fg2)
            }
            .monospacedDigit()
            Spacer()
            if n > 0 {
                Button("Seçimi kaldır") { model.selection.clear() }.buttonStyle(SoftButtonStyle())
            }
            Button("Önizle") { preview() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(n == 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.sidebar.opacity(0.7))
    }

    private func preview() {
        switch model.requestConfirm() {
        case .plan(let p): ui.sheet = .confirm(p)
        case .needsRescan: ui.sheet = .stale
        case .nothingSelected: break
        }
    }
}

struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            CategoryTile(tint: Theme.accent, symbol: "sparkles", size: 64)
            Text("Diskini tara").font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Cleaner önce yalnız bakar: hiçbir şeyi silmez, değiştirmez. Taramadan sonra neyin gideceğini sen seçersin; seçilenler Çöp Kutusu'na taşınır.")
                .multilineTextAlignment(.center).foregroundStyle(Theme.fg2).frame(maxWidth: 440)
            if let disk = model.disk {
                Text("Boş alan: \(Fmt.bytes(disk.availableBytes)) / \(Fmt.bytes(disk.totalBytes))")
                    .font(.system(size: 12)).foregroundStyle(Theme.fg2).monospacedDigit()
            }
            Button {
                Task { await model.startScan() }
            } label: {
                Label("Taramayı başlat", systemImage: "magnifyingglass").padding(.horizontal, 8).padding(.vertical, 3)
            }
            .buttonStyle(PrimaryButtonStyle())
            if let msg = model.errorMessage {
                Text(msg).font(.system(size: 12)).foregroundStyle(Theme.bad)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
