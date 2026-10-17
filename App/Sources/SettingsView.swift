import AppKit
import CleanerAppCore
import SwiftUI

/// Ayarlar penceresi: menü çubuğu, oturum açılışı ve bildirimler.
struct SettingsView: View {
    @Bindable var prefs: BackgroundPreferences
    let login: LoginItemModel
    let monitor: BackgroundMonitor

    var body: some View {
        Form {
            SwiftUI.Section("Genel") {
                Toggle("Menü çubuğunda boş alanı göster", isOn: $prefs.settings.showInMenuBar)
                Toggle("Mac açılınca Hepp Cleaner'ı başlat", isOn: Binding(
                    get: { prefs.settings.launchAtLogin },
                    set: { prefs.settings.launchAtLogin = $0; login.setEnabled($0) }))
                if let m = login.message {
                    HStack(alignment: .firstTextBaseline) {
                        Text(m).font(.callout).foregroundStyle(login.status == .requiresApproval ? Theme.warn : Theme.bad)
                            .fixedSize(horizontal: false, vertical: true)
                        if login.status == .requiresApproval {
                            Spacer()
                            Button("Aç") { open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension") }
                        }
                    }
                }
            }
            SwiftUI.Section {
                Toggle("Boş alan azalınca haber ver", isOn: $prefs.settings.lowSpaceEnabled)
                if prefs.settings.lowSpaceEnabled {
                    Stepper("\(prefs.settings.lowSpaceGB) GB'tan az kalırsa", value: $prefs.settings.lowSpaceGB, in: 1...2000, step: 5)
                    Stepper("ya da toplamın %\(prefs.settings.lowSpacePercent)'inden az kalırsa", value: $prefs.settings.lowSpacePercent, in: 1...50)
                    note("İkisinden hangisine önce inilirse haber verilir. Günde en fazla bir kez; alan yükselip tekrar düşerse yeniden.")
                }
                Toggle("Boş alan hızla azalınca haber ver", isOn: $prefs.settings.rapidDropEnabled)
                if prefs.settings.rapidDropEnabled {
                    Stepper("1 saatte \(prefs.settings.rapidDropGB) GB azalırsa", value: $prefs.settings.rapidDropGB, in: 1...2000)
                }
                Toggle("Haftalık özet", isOn: $prefs.settings.weeklyEnabled)
                if prefs.settings.weeklyEnabled {
                    Stepper("En az \(prefs.settings.weeklyMinGB) GB temizlenebilirse", value: $prefs.settings.weeklyMinGB, in: 1...2000)
                    note("Haftada bir arka planda önbellekler, Xcode, eski sürümler ve Docker taranır.")
                }
                if monitor.notificationsDenied {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Bildirimlere izin verilmedi, bu yüzden haber veremiyoruz.").font(.callout).foregroundStyle(Theme.warn)
                        Spacer()
                        Button("Ayarları aç") { open("x-apple.systempreferences:com.apple.Notifications-Settings.extension") }
                    }
                }
            } header: {
                Text("Bildirimler")
            } footer: {
                Text("Bildirim izni, ilk bildirim gönderileceği zaman istenir.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { login.refresh() }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

/// İlk açılışta oturum açılışı kaydı yapıldıysa pencerenin üstünde bir kez gösterilen kısa bilgi.
struct LoginNoticeBar: View {
    let login: LoginItemModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if login.showFirstRunNotice {
            Banner(symbol: "power", text: Text("Hepp Cleaner Mac açılınca kendiliğinden başlayacak ve menü çubuğunda boş alanı gösterecek. Ayarlar'dan kapatabilirsin."), trailing: {
                HStack(spacing: 10) {
                    Button("Ayarlar") { openSettings(); login.dismissNotice() }
                    Button("Tamam") { login.dismissNotice() }.buttonStyle(.borderedProminent)
                }
            })
            .padding([.horizontal, .top], 12)
        }
    }
}
