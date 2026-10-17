import AppKit
import CleanerAppCore
import SwiftUI

struct PermissionsSheet: View {
    let perms: PermissionModel
    var onContinue: () -> Void
    @State private var opened: Set<PermissionKind> = []

    var body: some View {
        SheetFrame {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    CategoryTile(tint: Theme.accent, symbol: "lock.shield", size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("İzinler").font(.system(size: 17, weight: .bold, design: .rounded))
                        Text("Hiçbiri zorunlu değil. Hepp Cleaner izinsiz de çalışır; yalnız ilgili işler yapılamaz.")
                            .foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(PermissionKind.allCases.enumerated()), id: \.element) { i, kind in
                        if i > 0 { Divider() }
                        row(kind)
                    }
                }
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
                Text("Uygulama güncellenince izinleri yeniden vermen gerekebilir.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.fg3)
                HStack {
                    Spacer()
                    Button("Devam et", action: onContinue).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func row(_ kind: PermissionKind) -> some View {
        let status = perms.status(kind)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(kind.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Badge(status: status)
            }
            Text(kind.reason).font(.system(size: 12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            if status != .granted {
                Text(kind.withoutIt).font(.system(size: 11.5)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Ayarları aç") {
                    if let url = URL(string: kind.settingsURL) { NSWorkspace.shared.open(url) }
                    opened.insert(kind)
                }.buttonStyle(SoftButtonStyle())
                if kind == .automation, status != .granted {
                    Button("Şimdi izin iste") { Task { await perms.requestAutomation() } }.buttonStyle(SoftButtonStyle())
                }
                if kind == .appManagement {
                    Button(perms.appManagementMarked ? "İşareti kaldır" : "Açtım") {
                        perms.setAppManagementMarked(!perms.appManagementMarked)
                    }.buttonStyle(SoftButtonStyle())
                }
            }
            if opened.contains(kind) {
                Text(kind == .fullDiskAccess
                     ? "İzni verdikten sonra Hepp Cleaner'ı kapatıp yeniden açman gerekebilir."
                     : "İzni verdikten sonra bu ekrana dön; durum kendiliğinden yenilenir.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.accent)
            }
            if kind == .appManagement, status != .granted {
                Text("macOS bu izni dışarıdan okutmaz; açtıysan \"Açtım\" ile işaretle.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.fg3)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

struct Badge: View {
    let status: PermissionStatus
    var body: some View {
        let (color, symbol): (Color, String) = switch status {
        case .granted: (Theme.ok, "checkmark.circle.fill")
        case .required: (Theme.warn, "exclamationmark.circle.fill")
        case .unverified: (Theme.mute, "questionmark.circle.fill")
        }
        Label(status.label, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
    }
}

/// Kenar çubuğu satırı: eksik izin varsa turuncu nokta.
struct PermissionsRow: View {
    let perms: PermissionModel
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                CategoryTile(tint: Theme.overviewTint, symbol: "lock.shield", size: 22)
                Text("İzinler").font(.system(size: 13))
                Spacer(minLength: 4)
                if perms.hasMissing { Circle().fill(Theme.warn).frame(width: 8, height: 8).accessibilityLabel("Eksik izin var") }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
