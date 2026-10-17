import AppKit
import CleanerAppCore
import CleanerKit
import SwiftUI

struct ResultView: View {
    let model: AppModel
    let ui: UIState
    let perms: PermissionModel

    var body: some View {
        Scroller {
            if let o = model.outcome {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 14) {
                        CategoryTile(tint: o.failedCount == 0 ? Theme.ok : (o.doneCount > 0 ? Theme.warn : Theme.bad),
                                     symbol: o.failedCount == 0 ? "checkmark" : "exclamationmark.triangle", size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            if o.failedCount > 0 {
                                Text(o.headline).font(.system(size: 20, weight: .bold, design: .rounded))
                                    .foregroundStyle(Theme.bad)
                            }
                            Text("Kazanılan alan").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.fg2)
                            Text(Fmt.bytes(o.freedBytes)).font(.system(size: o.failedCount > 0 ? 30 : 40, weight: .bold, design: .rounded))
                                .foregroundStyle(o.freedBytes > 0 ? Theme.ok : .primary).monospacedDigit()
                        }
                    }
                    if o.needsFullDiskAccess {
                        fullDiskAccessBanner
                    }
                    // Ret nedenleri üstte: kullanıcı önce neyin taşınamadığını görür.
                    if !o.refusedOther.isEmpty {
                        section("Taşınamadı · \(o.refusedOther.count)", tint: Theme.bad, lines: o.refusedOther)
                    }
                    if !o.appSkipGroups.isEmpty {
                        skippedLeftovers(o.appSkipGroups)
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

    /// Tam Disk Erişimi kaynaklı ret: izin durumunu (izinler ekranındaki tespit) söyler, Sistem Ayarları'na götürür.
    private var fullDiskAccessBanner: some View {
        let granted = perms.status(.fullDiskAccess) == .granted
        let text = granted
            ? "Bazı öğeler macOS uygulama verisi koruması yüzünden taşınamadı. Tam Disk Erişimi verilmiş görünüyor; "
                + "Hepp Cleaner yeniden derlendiyse izin kaybolmuş olabilir. Ayarlardan kapatıp açın, sonra Hepp Cleaner'ı yeniden başlatın."
            : "Bazı öğeler macOS uygulama verisi koruması yüzünden taşınamadı: Hepp Cleaner'ın Tam Disk Erişimi yok. "
                + "İzni verip Hepp Cleaner'ı yeniden başlattıktan sonra yeniden tarayın."
        return Banner(symbol: "lock.shield", tint: Theme.bad, text: Text(text)) {
            Button("Tam Disk Erişimi'ni aç") {
                if let url = URL(string: PermissionKind.fullDiskAccess.settingsURL) { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(SoftButtonStyle())
        }
    }

    /// Uygulaması taşınamadığı için atlanan artıklar, uygulamasının altında.
    private func skippedLeftovers(_ groups: [TrashOutcome.AppSkipGroup]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Uygulaması taşınamadığı için atlanan artıklar · \(groups.reduce(0) { $0 + $1.lines.count })")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warn)
            Panel {
                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                        if i > 0 { Divider().opacity(0.6) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(g.appName) taşınamadı; artıkları yerinde kaldı")
                                .font(.system(size: 12.5, weight: .semibold))
                            ForEach(g.lines) { l in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(Theme.fg3)
                                    Text(Fmt.tilde(l.path)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.fg2)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                .padding(.leading, 10)
                            }
                            Text("Uygulama taşınamadığı için artıkları da bırakıldı; uygulamayı kaldırdıktan sonra yeniden tarayıp artıkları ayrıca seçebilirsin.")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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
