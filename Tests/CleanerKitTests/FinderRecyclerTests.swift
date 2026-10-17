import AppKit
import CoreServices
import Foundation
import Testing
@testable import CleanerKit

/// `FinderRecycler`: olay kurulumu, yanıt/hata eşlemesi ve taşıma sonrası doğrulama. Gerçek Apple Event gönderilmez.
@Suite("Finder ile taşıma")
struct FinderRecyclerTests {
    func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    @Test("olay: hedef Finder, core/delo, doğrudan nesne typeFileURL")
    func deleteEventShape() throws {
        let url = URL(fileURLWithPath: "/Applications/Microsoft Word.app")
        let e = FinderRecycler.makeDeleteEvent(for: url)
        #expect(e.descriptorType == fourCC("aevt"))
        #expect(e.eventClass == fourCC("core"))
        #expect(e.eventID == fourCC("delo"))
        let target = try #require(e.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)))
        #expect(target.descriptorType == DescType(typeApplicationBundleID))
        #expect(String(data: target.data, encoding: .utf8) == "com.apple.finder")
        let direct = try #require(e.paramDescriptor(forKeyword: fourCC("----")))
        #expect(direct.descriptorType == fourCC("furl"))
        #expect(direct.fileURLValue?.path == url.path)
        // Başka parametre yok (yalnız doğrudan nesne).
        #expect(e.numberOfItems == 1)
    }

    @Test("yoldaki tırnak/AppleScript benzeri metin veri olarak kalır (enjeksiyon yok)")
    func pathIsDataNotScript() throws {
        let tricky = "/tmp/x\" & (do shell script \"echo pwned\") & \".app"
        let e = FinderRecycler.makeDeleteEvent(for: URL(fileURLWithPath: tricky))
        let direct = try #require(e.paramDescriptor(forKeyword: fourCC("----")))
        #expect(direct.descriptorType == fourCC("furl"))
        #expect(direct.fileURLValue?.path == tricky)
        #expect(e.eventClass == fourCC("core") && e.eventID == fourCC("delo"))
    }

    @Test("göreli parçalar standartlaştırılır")
    func standardizedTarget() throws {
        let e = FinderRecycler.makeDeleteEvent(for: URL(fileURLWithPath: "/Applications/./Foo.app"))
        #expect(e.paramDescriptor(forKeyword: fourCC("----"))?.fileURLValue?.path == "/Applications/Foo.app")
    }

    @Test("hata eşlemesi")
    func errorMapping() {
        #expect(FinderRecycler.mapError(code: -128, message: nil) == .userCancelled)
        #expect(FinderRecycler.mapError(code: -1743, message: "x") == .automationDenied)
        #expect(FinderRecycler.mapError(code: -1744, message: nil) == .automationConsentRequired)
        #expect(FinderRecycler.mapError(code: -1712, message: nil) == .timedOut)
        #expect(FinderRecycler.mapError(code: -600, message: nil) == .finderUnavailable)
        #expect(FinderRecycler.mapError(code: -609, message: nil) == .finderUnavailable)
        #expect(FinderRecycler.mapError(code: -5000, message: "erişim reddedildi")
            == .finderFailed(code: -5000, message: "erişim reddedildi"))
        #expect(FinderRecycler.mapError(code: -10000, message: "") == .finderFailed(code: -10000, message: nil))
        let denied = FinderRecycleError.automationDenied.localizedDescription
        #expect(denied.contains("Otomasyon") && denied.contains("Finder"))
        #expect(FinderRecycler.mapThrown(NSError(domain: NSOSStatusErrorDomain, code: -128)) == .userCancelled)
        #expect(FinderRecycler.mapThrown(FinderRecycleError.stillExists) == .stillExists)
    }

    @Test("yanıt: errn/errs okunur, hata yoksa nil")
    func replyErrors() {
        let ok = NSAppleEventDescriptor.appleEvent(withEventClass: fourCC("aevt"), eventID: fourCC("ansr"),
                                                   targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                                   transactionID: AETransactionID(kAnyTransactionID))
        #expect(FinderRecycler.replyError(ok) == nil)
        let bad = NSAppleEventDescriptor.appleEvent(withEventClass: fourCC("aevt"), eventID: fourCC("ansr"),
                                                    targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                                    transactionID: AETransactionID(kAnyTransactionID))
        bad.setParam(NSAppleEventDescriptor(int32: -1743), forKeyword: AEKeyword(keyErrorNumber))
        #expect(FinderRecycler.replyError(bad) == .automationDenied)
        let other = NSAppleEventDescriptor.appleEvent(withEventClass: fourCC("aevt"), eventID: fourCC("ansr"),
                                                      targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
        other.setParam(NSAppleEventDescriptor(int32: -5000), forKeyword: AEKeyword(keyErrorNumber))
        other.setParam(NSAppleEventDescriptor(string: "izin yok"), forKeyword: AEKeyword(keyErrorString))
        #expect(FinderRecycler.replyError(other) == .finderFailed(code: -5000, message: "izin yok"))
    }

    @Test("yanıt konumu: furl ise URL, değilse nil")
    func replyLocation() {
        func reply(_ direct: NSAppleEventDescriptor?) -> NSAppleEventDescriptor {
            let r = NSAppleEventDescriptor.appleEvent(withEventClass: fourCC("aevt"), eventID: fourCC("ansr"),
                                                      targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
            if let direct { r.setParam(direct, forKeyword: fourCC("----")) }
            return r
        }
        let trashed = URL(fileURLWithPath: "/Users/u/.Trash/Foo.app")
        #expect(FinderRecycler.resultingURL(from: reply(NSAppleEventDescriptor(fileURL: trashed)))?.path == trashed.path)
        #expect(FinderRecycler.resultingURL(from: reply(nil)) == nil)
        #expect(FinderRecycler.resultingURL(from: reply(NSAppleEventDescriptor.record())) == nil)
    }

    @Test("taşıma: gönderici ana iş parçacığında çağrılmaz; kaynak kalktıysa konum döner")
    func recycleSuccess() async throws {
        let t = try TempTree()
        let app = try t.dir("Apps/Foo.app", in: t.root)
        let bin = try t.dir("FakeTrash", in: t.root)
        let rec = FinderRecycler(timeout: 7) { url, timeout in
            #expect(!Thread.isMainThread)
            #expect(timeout == 7)
            let dest = bin.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
        let r = try await rec.recycle(app)
        #expect(r?.lastPathComponent == "Foo.app")
        #expect(!FileManager.default.fileExists(atPath: app.path))
    }

    @Test("taşıma: Finder başarı dese de kaynak duruyorsa başarı sayılmaz")
    func recycleStillExists() async throws {
        let t = try TempTree()
        let app = try t.dir("Apps/Foo.app", in: t.root)
        let rec = FinderRecycler { _, _ in nil }
        await #expect(throws: FinderRecycleError.stillExists) { try await rec.recycle(app) }
        #expect(FileManager.default.fileExists(atPath: app.path))
    }

    @Test("taşıma: gönderici hatası aynen iletilir ve Trasher dilinde okunur")
    func recycleError() async throws {
        let t = try TempTree()
        let app = try t.dir("Apps/Foo.app", in: t.root)
        let rec = FinderRecycler { _, _ in throw FinderRecycleError.userCancelled }
        await #expect(throws: FinderRecycleError.userCancelled) { try await rec.recycle(app) }
        #expect(Trasher.describe(FinderRecycleError.userCancelled).contains("iptal"))
    }
}
