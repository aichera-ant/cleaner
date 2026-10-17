import AppKit
import CleanerAppCore
import SwiftUI

/// İlk açılış akışı: pencerenin tamamını kaplar. 1) Tanıtım, 2) İzinler. İzinler zorunlu değildir.
struct OnboardingView: View {
    let onboarding: OnboardingModel
    let perms: PermissionModel
    let notifications: NotificationPermissionModel
    let loginItem: any LoginItemControlling
    var onFinish: () -> Void

    @State private var loginStatus: LoginItemStatus
    @State private var openedFDA = false
    @Environment(\.openSettings) private var openSettings

    init(onboarding: OnboardingModel, perms: PermissionModel, notifications: NotificationPermissionModel,
         loginItem: any LoginItemControlling, onFinish: @escaping () -> Void) {
        self.onboarding = onboarding
        self.perms = perms
        self.notifications = notifications
        self.loginItem = loginItem
        self.onFinish = onFinish
        _loginStatus = State(initialValue: loginItem.status)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            Group {
                switch onboarding.page {
                case .intro: intro
                case .permissions: permissionsPage
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            Spacer(minLength: 12)
            dots.padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshAll() }
        .task { refreshAll() }
    }

    private func refreshAll() {
        loginStatus = loginItem.status
        Task {
            await perms.refresh()
            await notifications.refresh()
        }
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingPage.allCases, id: \.self) { p in
                Circle().fill(p == onboarding.page ? Theme.accent : Theme.line).frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Sayfa 1: tanıtım

    private var intro: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityLabel("Hepp Cleaner")
            VStack(spacing: 6) {
                Text("Hepp Cleaner'a hoş geldin").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Diskini tarar, neyin yer kapladığını gösterir. Ne gideceğine her zaman sen karar verirsin.")
                    .foregroundStyle(Theme.fg2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                point("magnifyingglass", Theme.accent, "Önce yalnız bakar",
                      "Tarama sırasında hiçbir şeyi silmez ya da değiştirmez.")
                Divider()
                point("eye", Theme.ok, "Önce önizleme",
                      "Neyin gideceğini görür ve onaylarsın; onaylamadan hiçbir şey taşınmaz.")
                Divider()
                point("trash", Theme.tint(.caches), "Yalnız Çöp Kutusu'na taşır",
                      "Dosyalar kalıcı silinmez; Çöp Kutusu'ndan geri alabilirsin.")
                Divider()
                point("exclamationmark.triangle", Theme.warn, "Tek istisna: komutla silinenler",
                      "Docker gibi bazı şeyler komutla temizlenir ve geri alınamaz. Bunlar önizlemede ayrıca uyarılır.")
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
            Button {
                onboarding.next()
            } label: {
                Text("Devam").padding(.horizontal, 22).padding(.vertical, 3)
            }
            .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        }
    }

    private func point(_ symbol: String, _ tint: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CategoryTile(tint: tint, symbol: symbol, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: Sayfa 2: izinler

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CategoryTile(tint: Theme.accent, symbol: "lock.shield", size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("İzinler").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Hiçbiri zorunlu değil. Hepp Cleaner izinsiz de çalışır; yalnız ilgili işler yapılamaz. Sonra kenar çubuğundaki İzinler'den de verebilirsin.")
                        .foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 0) {
                fullDiskRow
                Divider()
                notificationRow
                Divider()
                loginRow
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
            HStack(spacing: 8) {
                Button("Geri") { onboarding.back() }.buttonStyle(SoftButtonStyle())
                Spacer()
                if perms.status(.fullDiskAccess) == .granted {
                    Button("Başla", action: onFinish).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                } else {
                    Button("Şimdilik geç", action: onFinish).buttonStyle(SoftButtonStyle())
                    Button("Başla", action: onFinish).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var fullDiskRow: some View {
        let kind = PermissionKind.fullDiskAccess
        let status = perms.status(kind)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(kind.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Badge(status: status)
            }
            Text(kind.reason).font(.system(size: 12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            if status != .granted {
                Text(kind.withoutIt).font(.system(size: 11.5)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
                Button("Sistem Ayarları'nı aç") {
                    if let url = URL(string: kind.settingsURL) { NSWorkspace.shared.open(url) }
                    openedFDA = true
                }.buttonStyle(SoftButtonStyle())
                if openedFDA {
                    Text("İzni verdikten sonra buraya dön; durum kendiliğinden yenilenir. Hepp Cleaner'ı kapatıp yeniden açman gerekebilir.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var notificationRow: some View {
        let auth = notifications.auth
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bildirimler").font(.system(size: 13, weight: .semibold))
                Spacer()
                Badge(status: auth.permissionStatus)
            }
            Text("Boş alan azalınca ve haftalık özet için haber verebilmek için.")
                .font(.system(size: 12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            if auth != .authorized {
                Text("İzinsiz de çalışır; uyarı almazsın.").font(.system(size: 11.5)).foregroundStyle(Theme.fg3)
                if notifications.canRequest {
                    Button("Bildirim izni iste") { Task { await notifications.request() } }.buttonStyle(SoftButtonStyle())
                } else {
                    Button("Sistem Ayarları'nı aç") {
                        if let url = URL(string: NotificationPermissionModel.settingsURL) { NSWorkspace.shared.open(url) }
                    }.buttonStyle(SoftButtonStyle())
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var loginRow: some View {
        let on = loginStatus == .enabled || loginStatus == .requiresApproval
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Oturum açılışında başlatma").font(.system(size: 13, weight: .semibold))
                Spacer()
                Label(on ? "Açık" : "Kapalı", systemImage: on ? "checkmark.circle.fill" : "minus.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Theme.ok : Theme.mute)
            }
            Text(on
                 ? "Hepp Cleaner Mac açılınca kendiliğinden başlar ve menü çubuğunda boş alanı gösterir. Ayarlar'dan istediğin zaman kapatabilirsin."
                 : "Hepp Cleaner Mac açılınca başlamıyor. Ayarlar'dan istediğin zaman açabilirsin.")
                .font(.system(size: 12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            if loginStatus == .requiresApproval {
                Text("Sistem Ayarları > Genel > Açılış Öğeleri'nde Hepp Cleaner'a izin vermen gerekiyor.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            Button("Ayarlar'ı aç") { openSettings() }.buttonStyle(SoftButtonStyle())
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}
