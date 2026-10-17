import Foundation
import Testing
@testable import CleanerAppCore

private func at(hours: Double) -> Date { Date(timeIntervalSince1970: 1_893_456_000 + hours * 3600) }

@Suite struct MenuSummaryTests {
    @Test("daha yeni özet seçilir; boşsa tarama yapılmadı denir")
    func latest() {
        let a = ScanSummary(date: at(hours: 1), cleanableBytes: 1)
        let b = ScanSummary(date: at(hours: 2), cleanableBytes: 2)
        #expect(MenuSummary.latest(window: a, background: b) == b)
        #expect(MenuSummary.latest(window: b, background: a) == b)
        #expect(MenuSummary.latest(window: nil, background: a) == a)
        #expect(MenuSummary.latest(window: nil, background: nil) == nil)
        #expect(MenuSummary.scanLine(nil, now: at(hours: 3)) == "Henüz tarama yapılmadı")
    }

    @Test("zaman ifadesi")
    func since() {
        #expect(MenuSummary.since(at(hours: 0), now: at(hours: 0.01)) == "az önce")
        #expect(MenuSummary.since(at(hours: 0), now: at(hours: 0.5)) == "30 dk önce")
        #expect(MenuSummary.since(at(hours: 0), now: at(hours: 5)) == "5 saat önce")
        #expect(MenuSummary.since(at(hours: 0), now: at(hours: 48)) == "2 gün önce")
    }

    @Test("eskimiş pencere taraması sayılmaz")
    func outdated() {
        #expect(MenuSummary.windowSummary(items: [], scannedAt: at(hours: 0), outdated: true) == nil)
        #expect(MenuSummary.windowSummary(items: [], scannedAt: nil, outdated: false) == nil)
        #expect(MenuSummary.windowSummary(items: [], scannedAt: at(hours: 0), outdated: false)?.cleanableBytes == 0)
    }
}
