import CleanerAppCore
import CleanerKit
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
    }

    var section: Section = .overview
    var sheet: Sheet?
}
