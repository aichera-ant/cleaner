import AppKit
import CoreServices
import Foundation

/// Finder'a Apple Event (`core/delo`, AppleScript'te `delete`) göndererek Çöp Kutusu'na taşır. Finder,
/// korunan (root sahipli ya da Uygulama Yönetimi korumalı) öğe için Finder'daki gibi parola/Touch ID ister.
///
/// YALNIZ `Trasher`'ın yetkili taşıyıcısı olarak, taze taramada `needsAuthorization` olan ve dar uygulama
/// istisnasını taşıma anında yeniden geçen `.app` paketi için kullanılır. CLI bunu vermez. Testte gerçek olay
/// gönderilmez (test `init(sender:)` ile sahte gönderici verir).
///
/// Güvenlik: yol hiçbir zaman script metnine gömülmez. Olay `NSAppleEventDescriptor` ile kurulur, hedef
/// doğrudan nesne olarak dosya URL tanımlayıcısı (`typeFileURL`) verilir.
public struct FinderRecycler: Recycling {
    /// Finder'ın paket kimliği (olay hedefi).
    public static let finderBundleID = "com.apple.finder"
    /// Kullanıcı parola penceresinde bekleyebilir: uzun zaman aşımı.
    public static let defaultTimeout: TimeInterval = 300

    /// Olayı gönderir; Çöp Kutusu'ndaki konumu (alınabildiyse) döner. Hata `FinderRecycleError` olmalıdır.
    typealias Sender = @Sendable (_ url: URL, _ timeout: TimeInterval) throws -> URL?

    let timeout: TimeInterval
    let sender: Sender

    public init(timeout: TimeInterval = FinderRecycler.defaultTimeout) {
        self.timeout = timeout
        self.sender = FinderRecycler.sendDeleteEvent
    }

    /// Test için: gerçek Apple Event yerine sahte gönderici.
    init(timeout: TimeInterval = FinderRecycler.defaultTimeout, sender: @escaping Sender) {
        self.timeout = timeout
        self.sender = sender
    }

    public func recycle(_ url: URL) async throws -> URL? {
        let sender = self.sender
        let timeout = self.timeout
        // Eşzamanlı (waitForReply) Apple Event ana iş parçacığında gönderilmez: yanıt beklerken (parola penceresi,
        // Otomasyon izni penceresi) arayüzü kilitler. Ayrı bir kuyrukta gönderilir, async arayüz bloklanmaz.
        let resulting: URL? = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try sender(url, timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        // Finder başarı dönse bile kaynak yol hâlâ duruyorsa başarı sayılmaz.
        if Self.itemExists(at: url) { throw FinderRecycleError.stillExists }
        return resulting
    }

    // MARK: - Saf parçalar (test edilir)

    /// `core/delo` olayı: hedef Finder, doğrudan nesne verilen dosya URL'si (`typeFileURL`). Gönderilmez.
    static func makeDeleteEvent(for url: URL) -> NSAppleEventDescriptor {
        let target = NSAppleEventDescriptor(bundleIdentifier: finderBundleID)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEDelete),
                                           targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(fileURL: url.standardizedFileURL), forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    /// Yanıttaki Apple Event hatası (`errn`/`errs`); hata yoksa nil.
    static func replyError(_ reply: NSAppleEventDescriptor) -> FinderRecycleError? {
        guard let code = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, code != 0 else {
            return nil
        }
        return mapError(code: Int(code), message: reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue)
    }

    /// Yanıttaki doğrudan nesne bir dosya URL'sine dönüşebiliyorsa onu döner. Finder çoğunlukla nesne belirteci
    /// döndürür (yerelde URL'ye çevrilemez); o zaman nil. Başka bir öğenin konumu tahmin edilmez.
    static func resultingURL(from reply: NSAppleEventDescriptor) -> URL? {
        guard let direct = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return nil }
        guard let furl = direct.coerce(toDescriptorType: DescType(typeFileURL)), let u = furl.fileURLValue,
              u.isFileURL else { return nil }
        return u
    }

    /// OSStatus / Apple Event hata kodunu anlaşılır hataya çevirir.
    static func mapError(code: Int, message: String?) -> FinderRecycleError {
        switch code {
        case Int(userCanceledErr): // -128
            return .userCancelled
        case Int(errAEEventNotPermitted), Int(errAEEventWouldRequireUserConsent): // -1743, -1744
            return .automationDenied
        case Int(errAETimeout): // -1712
            return .timedOut
        case Int(procNotFound), Int(connectionInvalid): // -600, -609
            return .finderUnavailable
        default:
            return .finderFailed(code: code, message: message?.isEmpty == false ? message : nil)
        }
    }

    /// Gönderim sırasında atılan hatayı eşler (NSAppleEventDescriptor `NSOSStatusErrorDomain` ile atar).
    static func mapThrown(_ error: any Error) -> FinderRecycleError {
        if let e = error as? FinderRecycleError { return e }
        let ns = error as NSError
        return mapError(code: ns.code, message: ns.localizedFailureReason ?? ns.localizedDescription)
    }

    /// Yol (sembolik bağ izlenmeden) hâlâ var mı.
    static func itemExists(at url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    // MARK: - Gerçek gönderim (testte çağrılmaz)

    private static let sendDeleteEvent: Sender = { url, timeout in
        let event = makeDeleteEvent(for: url)
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: timeout)
        } catch {
            throw mapThrown(error)
        }
        if let error = replyError(reply) { throw error }
        return resultingURL(from: reply)
    }
}

/// Finder ile taşıma hataları (Türkçe, `Trasher` raporunda gösterilir).
public enum FinderRecycleError: Error, Equatable, LocalizedError, Sendable {
    case userCancelled
    case automationDenied
    case timedOut
    case finderUnavailable
    case finderFailed(code: Int, message: String?)
    case stillExists

    public var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "yetki penceresi iptal edildi; öğe taşınmadı"
        case .automationDenied:
            return "Cleaner'ın Finder'ı kullanma izni yok. Sistem Ayarları → Gizlilik ve Güvenlik → Otomasyon → "
                + "Cleaner → Finder iznini açıp yeniden deneyin"
        case .timedOut:
            return "Finder zamanında yanıt vermedi (zaman aşımı); öğe taşınmamış olabilir, yeniden tarayın"
        case .finderUnavailable:
            return "Finder'a ulaşılamadı; Finder'ın açık olduğundan emin olup yeniden deneyin"
        case let .finderFailed(code, message):
            if let message { return "Finder taşıyamadı (\(code)): \(message)" }
            return "Finder taşıyamadı (hata \(code))"
        case .stillExists:
            return "Finder işlemi bitirdi ama öğe hâlâ yerinde; taşınmış sayılmadı"
        }
    }
}
