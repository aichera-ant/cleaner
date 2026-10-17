import CleanerKit
import Foundation

/// Kategorinin arayüzdeki adı, bölümü ve açıklaması (Türkçe). Simge SF Symbol adıdır.
public struct CategoryInfo: Sendable, Equatable, Identifiable {
    // ip2-core: `ItemCategory` typealias'ı gelince `CleanerKit.Category` yerine o yazılır.
    public var category: CleanerKit.Category
    public var title: String
    public var section: String
    public var blurb: String
    public var symbol: String
    public var id: CleanerKit.Category { category }

    public static let all: [CategoryInfo] = [
        .init(category: .xcode, title: "Xcode", section: "Geliştirici",
              blurb: "Derleme çıktıları ve simülatörler. DerivedData her zaman yeniden oluşur; açık simülatöre dokunulmaz.",
              symbol: "hammer"),
        .init(category: .projectArtifacts, title: "Proje artıkları", section: "Geliştirici",
              blurb: "node_modules, .next ve .turbo. 30 günden uzun süredir dokunulmayanlar seçili gelir; yeni kullanılanlar kilitlidir.",
              symbol: "folder.badge.gearshape"),
        .init(category: .caches, title: "Önbellekler", section: "Geliştirici",
              blurb: "Paket yöneticisi ve uygulama önbellekleri. Gerektiğinde yeniden oluşur ya da indirilir.",
              symbol: "square.stack.3d.up"),
        .init(category: .docker, title: "Docker", section: "Geliştirici",
              blurb: "docker komutlarıyla okunur. Çalışan container ve kullandığı image kilitlidir.",
              symbol: "shippingbox"),
        .init(category: .oldVersions, title: "Eski sürümler", section: "Geliştirici",
              blurb: "Aynı aracın birden fazla sürümü. En yenisi kalır, eskiler önerilir.",
              symbol: "clock.arrow.circlepath"),
        .init(category: .largeOld, title: "Büyük ve eski", section: "Dosyalar",
              blurb: "50 MB üstü dosya ve klasörler, boyuta göre. Kural listesinde olmayanlar kırmızı gelir; kararı sen verirsin.",
              symbol: "doc.badge.arrow.up"),
        .init(category: .duplicates, title: "Mükerrer dosyalar", section: "Dosyalar",
              blurb: "İçeriği birebir aynı dosyalar. Her grupta bir kopya tutulur, gerisi önerilir. Hangisinin kalacağını sen değiştirebilirsin.",
              symbol: "doc.on.doc"),
        .init(category: .folders, title: "İlişkili klasörler", section: "Dosyalar",
              blurb: "Boş ya da artık klasörler ve birbirine benzeyen projeler.",
              symbol: "folder"),
        .init(category: .apps, title: "Uygulamalar", section: "Uygulamalar",
              blurb: "Uzun süredir açılmayan uygulamalar ve ~/Library altında bıraktıkları dosyalar. Son açılış Spotlight kaydından gelir.",
              symbol: "square.grid.2x2"),
    ]

    public static func info(for category: CleanerKit.Category) -> CategoryInfo {
        all.first { $0.category == category }!
    }

    /// Kenar çubuğu bölümleri sırayla.
    public static var sections: [(name: String, categories: [CategoryInfo])] {
        var out: [(String, [CategoryInfo])] = []
        for c in all {
            if let i = out.firstIndex(where: { $0.0 == c.section }) { out[i].1.append(c) } else { out.append((c.section, [c])) }
        }
        return out
    }
}
