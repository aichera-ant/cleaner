import CleanerKit
import Foundation

/// Menü çubuğu menüsündeki satırlar; saf, saat enjekte edilir.
public enum MenuSummary {
    /// Pencere taramasıyla (varsa, güncel) arka plan taramasından yenisini seçer.
    public static func latest(window: ScanSummary?, background: ScanSummary?) -> ScanSummary? {
        switch (window, background) {
        case (nil, nil): nil
        case (let w?, nil): w
        case (nil, let b?): b
        case (let w?, let b?): w.date >= b.date ? w : b
        }
    }

    public static func windowSummary(items: [CleanItem], scannedAt: Date?, outdated: Bool) -> ScanSummary? {
        guard let scannedAt, !outdated else { return nil }
        return ScanSummary(date: scannedAt, cleanableBytes: Summaries.cleanableBytes(items, selection: SelectionState(defaultsFrom: items)))
    }

    public static func diskLine(_ d: DiskInfo?) -> String {
        guard let d else { return "Boş alan okunamadı" }
        return "Boş alan: \(Fmt.bytes(d.availableBytes)) / \(Fmt.bytes(d.totalBytes))"
    }

    public static func scanLine(_ s: ScanSummary?, now: Date) -> String {
        guard let s else { return "Henüz tarama yapılmadı" }
        return "Son tarama \(since(s.date, now: now)): \(Fmt.bytes(s.cleanableBytes)) temizlenebilir"
    }

    static func since(_ date: Date, now: Date) -> String {
        let sec = now.timeIntervalSince(date)
        if sec < 90 { return "az önce" }
        if sec < 3600 { return "\(Int(sec / 60)) dk önce" }
        if sec < 86_400 { return "\(Int(sec / 3600)) saat önce" }
        return Fmt.ago(Int(sec / 86_400))
    }
}
