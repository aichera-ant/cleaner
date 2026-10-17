import CleanerKit
import Foundation

/// "Finder'da göster" kararı. Dataless (yalnız bulutta) ya da bulut klasörü altındaki öğe seçilerek gösterilmez:
/// Finder'ın dosyayı seçmesi indirmeyi tetikleyebilir; bunun yerine üst klasör açılır. İçerik okunmaz.
public enum RevealTarget: Equatable, Sendable {
    case select(String)
    case openParent(String)

    public static func decide(path: String, guardian: CloudGuard = CloudGuard(home: FileManager.default.homeDirectoryForCurrentUser)) -> RevealTarget {
        let url = URL(fileURLWithPath: path)
        let cloudy = guardian.isUnderCloudRoot(url)
            || guardian.probes.isDataless(url)
            || guardian.probes.isDownloadedCurrent(url) == false
        return cloudy ? .openParent(url.deletingLastPathComponent().path) : .select(path)
    }
}
