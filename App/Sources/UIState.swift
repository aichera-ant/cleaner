import CleanerAppCore
import CleanerKit
import Observation

enum Section: Hashable {
    case overview
    case category(CleanerKit.Category)
}

@MainActor
@Observable
final class UIState {
    enum Sheet: Equatable {
        case confirm(TrashPlan)
        case stale
    }

    var section: Section = .overview
    var sheet: Sheet?
}
