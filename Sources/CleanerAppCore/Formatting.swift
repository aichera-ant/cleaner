import CleanerKit
import Foundation

public enum Fmt {
    public static func bytes(_ b: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false // "Zero KB" yerine "0 KB"
        return f.string(fromByteCount: Int64(clamping: b))
    }

    /// Risk rozeti metni (demo ile aynı).
    public static func riskLabel(_ item: CleanItem) -> String {
        if item.isLocked { return "Kullanımda" }
        switch item.risk {
        case .green: return item.category == .duplicates ? "Aynısı duruyor" : "Yeniden oluşur"
        case .yellow: return "Yeniden indirilir"
        case .red: return "Karar senin"
        case .locked: return "Kullanımda"
        case .info: return "Taşınamaz"
        }
    }

    /// Tarih sinyali: (etiket, değer).
    public static func dateText(_ s: DateSignal) -> (label: String, value: String) {
        switch s {
        case .unknown: return ("son kullanım", "bilinmiyor")
        case .opened(let d): return ("açıldı", ago(d))
        case .modified(let d): return ("değişti", ago(d))
        }
    }

    public static func ago(_ n: Int) -> String {
        switch n {
        case 0: "bugün"
        case 1: "dün"
        case ..<60: "\(n) gün önce"
        case ..<365: "\(Int((Double(n) / 30).rounded())) ay önce"
        default: "\(Int((Double(n) / 365).rounded())) yıl önce"
        }
    }

    /// Yolu `~` ile kısaltır.
    public static func tilde(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// macOS korumalı uygulama: taşırken parola ya da Touch ID isteyecek mi?
    public static func needsAuthorization(_ item: CleanItem) -> Bool {
        item.needsAuthorization == true
    }
}
