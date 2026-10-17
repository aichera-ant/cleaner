import CleanerAppCore
import CleanerKit
import SwiftUI

struct ResultView: View {
    let model: AppModel
    let ui: UIState

    var body: some View {
        Scroller {
            if let o = model.outcome {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 14) {
                        CategoryTile(tint: o.doneCount > 0 ? Theme.ok : Theme.warn,
                                     symbol: o.doneCount > 0 ? "checkmark" : "exclamationmark.triangle", size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Kazanılan alan").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.fg2)
                            Text(Fmt.bytes(o.freedBytes)).font(.system(size: 40, weight: .bold, design: .rounded))
                                .foregroundStyle(o.freedBytes > 0 ? Theme.ok : .primary).monospacedDigit()
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if o.trashedCount > 0 {
                            Label("**\(o.trashedCount) öğe** Çöp Kutusu'na taşındı (\(Fmt.bytes(o.trashedBytes))). Yer, Çöp Kutusu boşaltılınca açılır; o zamana kadar geri alabilirsin.", systemImage: "trash")
                        }
                        if o.commandCount > 0 {
                            Label("**\(o.commandCount) öğe** komutla temizlendi (\(Fmt.bytes(o.commandBytes))). Bunlar Çöp Kutusu'na gitmedi.", systemImage: "terminal")
                        }
                    }
                    .foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)

                    if !o.refused.isEmpty {
                        section("Reddedilenler · \(o.refused.count)", tint: Theme.bad, lines: o.refused)
                    }
                    if !o.skipped.isEmpty {
                        section("Atlananlar · \(o.skipped.count)", tint: Theme.warn, lines: o.skipped)
                    }
                    Banner(symbol: "arrow.clockwise", tint: Theme.mute,
                           text: Text("Bu tarama sonucu artık güncel değil. Güncel durumu görmek için yeniden tara."))
                    HStack(spacing: 8) {
                        Button { Actions.openTrash() } label: { Label("Çöp Kutusu'nu aç", systemImage: "trash") }
                            .buttonStyle(SoftButtonStyle())
                        Button("Kapat") { model.dismissResult() }.buttonStyle(SoftButtonStyle())
                        Spacer()
                        Button { Task { await model.startScan() } } label: { Label("Yeniden tara", systemImage: "arrow.clockwise") }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 22)
            }
        }
    }

    private func section(_ title: String, tint: Color, lines: [TrashOutcome.Line]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            Panel {
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        if i > 0 { Divider().opacity(0.6) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.name).font(.system(size: 12.5, weight: .semibold))
                            if !l.path.isEmpty {
                                Text(Fmt.tilde(l.path)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.fg2)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Text(l.reason).font(.system(size: 11.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}
