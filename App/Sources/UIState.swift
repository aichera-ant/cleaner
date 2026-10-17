import CleanerAppCore
import CleanerKit
import Foundation
import Observation

enum Section: Hashable {
    case overview
    case category(ItemCategory)
}

@MainActor
@Observable
final class UIState {
    enum Sheet: Equatable {
        case confirm(TrashPlan)
        case stale
        /// Akıllı seçimde taşınacak öğe yok.
        case nothingToClean
        case permissions
        /// "Uygulama ve artıkları": verilen uygulama öğesinin artık seçimi.
        case appLeftovers(String)
    }

    /// İlk açılış akışı; yalnız ilk açılışta dolu, bitince nil.
    var onboarding: OnboardingModel? = OnboardingFlow.shouldShow() ? OnboardingModel() : nil
    var notifications = NotificationPermissionModel()
    var loginItem: any LoginItemControlling = LiveLoginItem()

    var section: Section = .overview
    var sheet: Sheet?
    /// Uygulamalar sayfasında artıkları açık olan uygulamalar (varsayılan: hepsi kapalı).
    var expandedApps: Set<String> = []
    /// Taşıma sonunda Uygulama Yönetimi reddi görüldü; sonuç gösterilince izin ekranı yeniden önerilir.
    var pendingPermissions = false
    /// Kategori listelerinin ortak sıralaması; UserDefaults'ta hatırlanır.
    var sort: ItemSort = ItemSort(rawValue: UserDefaults.standard.string(forKey: "itemSort") ?? "") ?? .sizeDescending {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "itemSort") }
    }
}
