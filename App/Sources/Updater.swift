import Combine
import Foundation
import Observation
import Sparkle

/// Sparkle 2 otomatik güncelleme sarmalayıcısı.
/// Ayarlar Info.plist'te (App/project.yml): günde bir denetler, indirip kurmadan önce sorar.
/// Appcast ve DMG GitHub Releases'te; güncellemeler EdDSA ile imzalı (docs/DAGITIM.md).
@MainActor
@Observable
final class Updater {
    /// "Güncellemeleri denetle…" menü öğesinin etkinliği (Sparkle bir denetim ya da kurulum sürerken false).
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: AnyCancellable?

    /// - Parameter start: false ise Sparkle başlatılmaz (ör. --snapshot kipi); menü öğesi devre dışı kalır.
    init(start: Bool = true) {
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
        guard start else { return }
        // SPUUpdater ana iş parçacığında çalışır; KVO değişiklikleri de oradan gelir.
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
