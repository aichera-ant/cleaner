import AppKit
import CleanerAppCore
import CleanerKit
import SwiftUI

struct Pill: View {
    var text: String
    var color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(color.opacity(0.13), in: Capsule())
    }
}

struct CategoryTile: View {
    var tint: Color
    var symbol: String
    var size: CGFloat = 22
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint)
            .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.52, weight: .semibold)).foregroundStyle(.white))
    }
}

struct CheckBox: View {
    var on: Bool
    var enabled: Bool = true
    var lockHelp: String?
    var action: () -> Void
    var body: some View {
        Group {
            if enabled {
                Button(action: action) {
                    Image(systemName: on ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16))
                        .foregroundStyle(on ? Theme.accent : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(on ? "Seçili" : "Seç")
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.fg3)
                    .help(lockHelp ?? "Seçilemez")
                    .accessibilityLabel("Kilitli")
            }
        }
        .frame(width: 22, height: 22)
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct Banner<Trailing: View>: View {
    var symbol: String
    var tint: Color = Theme.accent
    var text: Text
    var trailing: Trailing

    init(symbol: String, tint: Color = Theme.accent, text: Text, @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.tint = tint
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 15, weight: .semibold))
            text.font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension Banner where Trailing == EmptyView {
    init(symbol: String, tint: Color = Theme.accent, text: Text) {
        self.init(symbol: symbol, tint: tint, text: text) { EmptyView() }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var danger = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .foregroundStyle(.white)
            .background((danger ? Theme.bad : Theme.accent).opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SoftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(enabled ? 1 : 0.5)
    }
}

/// Sidebar arka planı: uygulamada cam, PNG çiziminde düz renk.
struct SidebarBackground: View {
    @Environment(\.snapshotMode) private var snapshot
    var body: some View {
        if snapshot { Theme.sidebar } else { VisualEffect(material: .sidebar) }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Pencere arka planına tutunup başlık çubuğunu şeffaflaştırır, pencere sürüklenebilir olur.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.styleMask.insert(.fullSizeContentView)
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

enum Actions {
    static func reveal(_ path: String) {
        switch RevealTarget.decide(path: path) {
        case .select(let p): NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        case .openParent(let p): NSWorkspace.shared.open(URL(fileURLWithPath: p, isDirectory: true))
        }
    }

    static func openTrash() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash"))
    }
}

/// Kaydırma alanı. PNG çiziminde (`ImageRenderer`) ScrollView boş çizildiği için içerik doğrudan üstten dizilir ve kırpılır.
struct Scroller<Content: View>: View {
    @Environment(\.snapshotMode) private var snapshot
    @ViewBuilder var content: Content
    var body: some View {
        if snapshot {
            // İçerik boyutu yerleşimi etkilemesin: esnek bir zeminin üstüne bindirilir.
            Color.clear
                .overlay(alignment: .top) { content.fixedSize(horizontal: false, vertical: true) }
                .clipped()
        } else {
            ScrollView { content }
        }
    }
}
