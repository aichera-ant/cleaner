import CleanerAppCore
import CleanerKit
import SwiftUI

/// Pencerenin üstünden inen sayfa (demodaki gibi). Gerçek `.sheet` yerine kaplama: hem PNG'ye çizilebilir hem aynı görünür.
struct SheetLayer: View {
    let model: AppModel
    let ui: UIState

    var body: some View {
        ZStack(alignment: .top) {
            if model.phase == .moving {
                Color.black.opacity(0.2)
                MovingSheet()
            } else if let sheet = ui.sheet {
                Color.black.opacity(0.2).onTapGesture { ui.sheet = nil }
                switch sheet {
                case .confirm(let plan):
                    ConfirmSheet(plan: plan, onCancel: { ui.sheet = nil }, onConfirm: { move(plan) })
                case .stale:
                    StaleSheet(onCancel: { ui.sheet = nil }, onRescan: {
                        ui.sheet = nil
                        Task { await model.startScan() }
                    })
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: ui.sheet)
        .allowsHitTesting(model.phase == .moving || ui.sheet != nil)
    }

    private func move(_ plan: TrashPlan) {
        Task {
            let r = await model.confirmMove(plan)
            ui.sheet = nil
            if model.phase != .result, r == .needsRescan { ui.sheet = .stale }
        }
    }
}

struct SheetFrame<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: 560)
            .background(Theme.window, in: UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous))
            .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
            .padding(.horizontal, 12)
            .transition(.move(edge: .top))
    }
}

struct ConfirmSheet: View {
    let plan: TrashPlan
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        SheetFrame {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    CategoryTile(tint: Theme.accent, symbol: "trash", size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(plan.itemCount) öğe · \(Fmt.bytes(plan.totalBytes))").font(.system(size: 17, weight: .bold, design: .rounded))
                        Text("Çöp Kutusu'na gidenler boşaltana kadar geri alınabilir.").foregroundStyle(Theme.fg2)
                    }
                }
                if !plan.nonGreen.isEmpty {
                    Text("**\(plan.nonGreen.count) öğe yeşil değil:** \(plan.nonGreen.map(\.name).joined(separator: ", ")). Bunları sen seçtin; yeniden indirme ya da veri kaybı olabilir.")
                        .font(.system(size: 12)).foregroundStyle(Theme.fg2)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.warn.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                Scroller {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(plan.trashGroups.enumerated()), id: \.offset) { _, g in
                            header("\(CategoryInfo.info(for: g.category).title) · \(Fmt.bytes(Summaries.totalBytes(g.items)))")
                            ForEach(g.items) { line($0) }
                        }
                        if !plan.commandItems.isEmpty {
                            header("Komutla temizlenecek · Çöp Kutusu'na gitmez · \(Fmt.bytes(plan.commandBytes))")
                            ForEach(plan.commandItems) { line($0) }
                        }
                    }
                }
                .frame(maxHeight: 300)
                .clipped()
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                HStack(spacing: 8) {
                    Text("\(plan.trashCount) taşınacak · \(plan.commandItems.count) komut").foregroundStyle(Theme.fg2).monospacedDigit()
                    Spacer()
                    Button("Vazgeç", action: onCancel).buttonStyle(SoftButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("Çöp Kutusu'na taşı", action: onConfirm).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Taşıma önizlemesi")
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.fg2)
            .padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.hover)
    }

    private func line(_ item: CleanItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12))
                Text(Fmt.tilde(item.path)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.fg2)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Text(Fmt.bytes(item.allocatedBytes)).font(.system(size: 12, weight: .bold)).monospacedDigit()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
}

struct StaleSheet: View {
    var onCancel: () -> Void
    var onRescan: () -> Void

    var body: some View {
        SheetFrame {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    CategoryTile(tint: Theme.warn, symbol: "clock.badge.exclamationmark", size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tarama eskidi").font(.system(size: 17, weight: .bold, design: .rounded))
                        Text("Son taramadan 15 dakikadan fazla geçti ya da liste güncel değil. Dosyalar bu sürede değişmiş olabilir; taşımadan önce yeniden taranır.")
                            .foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Spacer()
                    Button("Vazgeç", action: onCancel).buttonStyle(SoftButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("Yeniden tara", action: onRescan).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

struct MovingSheet: View {
    var body: some View {
        SheetFrame {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Taşınıyor… macOS gerekirse parola ya da Touch ID isteyebilir.").foregroundStyle(Theme.fg2)
                Spacer()
            }
        }
    }
}
