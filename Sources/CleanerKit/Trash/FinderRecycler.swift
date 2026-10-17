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
    /// Toplu olayı (tek `core/delo`, doğrudan nesne `typeAEList`) gönderir. Hata `FinderRecycleError` olmalıdır.
    typealias BatchSender = @Sendable (_ urls: [URL], _ timeout: TimeInterval) throws -> Void
    /// Bekleme (yedekten önce toplu olayın geç bitmesine pay). Testte anında döner.
    typealias Sleeper = @Sendable (_ duration: Duration) async -> Void

    /// Toplu olaydan sonra öğe yerindeyse yedekten önce kaç kez beklenip yeniden `lstat` yapılır (adım başına
    /// `settleStep`; en çok ~1,5 sn). Finder toplu olayı geç bitirdiyse ikinci parola penceresi açılmasın diye.
    static let settlePolls = 3
    static let settleStep: Duration = .milliseconds(500)

    let timeout: TimeInterval
    let sender: Sender
    let batchSender: BatchSender
    let sleeper: Sleeper

    public init(timeout: TimeInterval = FinderRecycler.defaultTimeout) {
        self.timeout = timeout
        self.sender = FinderRecycler.sendDeleteEvent
        self.batchSender = FinderRecycler.sendBatchDeleteEvent
        self.sleeper = { d in try? await Task.sleep(for: d) }
    }

    /// Test için: gerçek Apple Event yerine sahte gönderici(ler); bekleme varsayılan olarak anında döner.
    init(timeout: TimeInterval = FinderRecycler.defaultTimeout, sender: @escaping Sender,
         batchSender: BatchSender? = nil, sleeper: Sleeper? = nil) {
        self.timeout = timeout
        self.sender = sender
        self.batchSender = batchSender ?? { urls, t in for u in urls { _ = try sender(u, t) } }
        self.sleeper = sleeper ?? { _ in }
    }

    public func recycle(_ urls: [URL]) async -> [URL: Result<URL?, any Error>] {
        await recycle(urls, revalidate: { _ in nil })
    }

    /// Birden çok yolu taşır.
    ///
    /// - Tek öğe: doğrudan TEK öğeli olay (gerçek Finder'la doğrulanmış biçim; toplu liste gönderilmez). Olay hata
    ///   dönse bile öğe yerinden kalktıysa başarılıdır (konum nil).
    /// - Birden çok öğe: önce TEK toplu olay (Finder bir kez parola/Touch ID ister). Olaydan sonra her kaynak ayrı
    ///   ayrı `lstat` ile doğrulanır: kalkan başarılı (konum nil). Olay hata dönse bile (Finder bir kısmını taşımış
    ///   olabilir) kalkan başarılıdır.
    /// - Yerinde kalanlar: toplu olay başarı dediği hâlde öğe duruyorsa (`stillExists`) ya da Finder genel bir hata
    ///   döndüyse (`finderFailed`) önce kısa beklenip (`settlePolls` × `settleStep`) yeniden `lstat` yapılır; hâlâ
    ///   duran her öğe `revalidate` ile yeniden doğrulanır (nil değilse ret nedeni: öğe Finder'a gitmez) ve TEK öğeli
    ///   olaya sırayla yedek düşülür (her biri ayrı parola isteyebilir). Tek öğeli olay hata dönse bile öğe kalktıysa
    ///   başarılıdır. Kullanıcı iptali, Otomasyon izni yok/onay gerekli, bekleme iptali, Finder'a ulaşılamadı ve zaman
    ///   aşımında yedek denenmez (kullanıcıya yeniden sorulmaz); yedek sırasında bunlardan biri gelirse kalanlar da o
    ///   hatayla biter.
    public func recycle(_ urls: [URL], revalidate: @escaping @Sendable (URL) -> String?) async
        -> [URL: Result<URL?, any Error>] {
        guard !urls.isEmpty else { return [:] }
        let log = TrashLog.logger
        if urls.count == 1 {
            let u = urls[0]
            do { return [u: .success(try await recycle(u))] } catch { return [u: .failure(error)] }
        }
        log.info("Finder toplu olay gönderiliyor: \(urls.count, privacy: .public) öğe")
        let batchSender = self.batchSender
        let timeout = self.timeout
        let failure: FinderRecycleError? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try batchSender(urls, timeout)
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: FinderRecycler.mapThrown(error))
                }
            }
        }
        if let failure {
            log.error("Finder toplu olay hatası: kod \(failure.code ?? 0, privacy: .public), \(failure.logText, privacy: .public)")
        }
        var out: [URL: Result<URL?, any Error>] = [:]
        var remaining: [URL] = []
        func sweep(_ candidates: [URL]) {
            remaining = []
            for u in candidates {
                if Self.itemExists(at: u) {
                    remaining.append(u)
                } else {
                    out[u] = .success(nil)
                    log.info("Finder (toplu): taşındı \(u.path, privacy: .public)")
                }
            }
        }
        sweep(urls)
        guard !remaining.isEmpty else { return out }
        let batchError = failure ?? FinderRecycleError.stillExists
        guard Self.fallsBackToSingle(after: batchError) else {
            for u in remaining {
                out[u] = .failure(batchError)
                log.error("Finder (toplu): reddedildi \(u.path, privacy: .public): \(batchError.logText, privacy: .public)")
            }
            return out
        }
        // Finder toplu olayı geç bitirmiş olabilir: kısa bekleyip yeniden bak (ikinci parola penceresi açılmasın).
        for _ in 0..<Self.settlePolls where !remaining.isEmpty {
            await sleeper(Self.settleStep)
            sweep(remaining)
        }
        guard !remaining.isEmpty else { return out }
        log.notice("Finder toplu olayından sonra \(remaining.count, privacy: .public) öğe yerinde; tek öğeli olaya yedek düşülüyor")
        var stop: FinderRecycleError?
        for u in remaining {
            if let stop {
                out[u] = .failure(stop)
                log.error("Finder (yedek): denenmedi \(u.path, privacy: .public): \(stop.logText, privacy: .public)")
                continue
            }
            // Yedek olaydan hemen önce yol yeniden doğrulanır (toplu olaydan bu yana durum değişmiş olabilir).
            if let reason = revalidate(u) {
                let e = FinderRecycleError.revalidationFailed(reason)
                out[u] = .failure(e)
                log.error("Finder (yedek): yeniden doğrulamada reddedildi \(u.path, privacy: .public): \(reason, privacy: .public)")
                continue
            }
            do {
                out[u] = .success(try await recycle(u))
            } catch {
                let e = Self.mapThrown(error)
                out[u] = .failure(e)
                if Self.stopsFallback(e) { stop = e }
            }
        }
        return out
    }

    /// Toplu olaydan sonra yerinde kalan öğeler için tek öğeli olaya düşülür mü?
    static func fallsBackToSingle(after error: FinderRecycleError) -> Bool {
        switch error {
        case .stillExists, .finderFailed: true
        case .userCancelled, .automationDenied, .automationConsentRequired, .waitCancelled, .finderUnavailable,
             .timedOut, .revalidationFailed: false
        }
    }

    /// Yedek sırasında bu hata gelirse kalan öğeler denenmez (kullanıcıya yeniden sorulmaz).
    static func stopsFallback(_ error: FinderRecycleError) -> Bool { !fallsBackToSingle(after: error) }

    public func recycle(_ url: URL) async throws -> URL? {
        let sender = self.sender
        let timeout = self.timeout
        let log = TrashLog.logger
        log.info("Finder tek öğeli olay gönderiliyor: \(url.path, privacy: .public)")
        // Eşzamanlı (waitForReply) Apple Event ana iş parçacığında gönderilmez: yanıt beklerken (parola penceresi,
        // Otomasyon izni penceresi) arayüzü kilitler. Ayrı bir kuyrukta gönderilir, async arayüz bloklanmaz.
        let resulting: URL?
        do {
            resulting = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try sender(url, timeout))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            let e = Self.mapThrown(error)
            // Olay hata dönse bile öğe yerinden kalktıysa başarı sayılır (toplu yoldaki kural; konum bilinmez).
            if !Self.itemExists(at: url) {
                log.notice("Finder hata döndü (kod \(e.code ?? 0, privacy: .public)) ama öğe kalktı: \(url.path, privacy: .public)")
                return nil
            }
            log.error("Finder: reddedildi \(url.path, privacy: .public): kod \(e.code ?? 0, privacy: .public), \(e.logText, privacy: .public)")
            throw e
        }
        // Finder başarı dönse bile kaynak yol hâlâ duruyorsa başarı sayılmaz.
        if Self.itemExists(at: url) {
            log.error("Finder başarı döndü ama öğe yerinde: \(url.path, privacy: .public)")
            throw FinderRecycleError.stillExists
        }
        log.info("Finder: taşındı \(url.path, privacy: .public)")
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

    /// Toplu `core/delo` olayı: doğrudan nesne `typeAEList`, her öğe `typeFileURL` (metin gömme yok). Gönderilmez.
    static func makeDeleteEvent(for urls: [URL]) -> NSAppleEventDescriptor {
        let target = NSAppleEventDescriptor(bundleIdentifier: finderBundleID)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEDelete),
                                           targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        let list = NSAppleEventDescriptor.list()
        for (i, u) in urls.enumerated() {
            list.insert(NSAppleEventDescriptor(fileURL: u.standardizedFileURL), at: i + 1)
        }
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
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

    /// OSStatus / Apple Event hata kodunu anlaşılır hataya çevirir. Bilinen kodlar (iptal, Otomasyon izni, zaman
    /// aşımı, Finder yok) sade Türkçe metne döner; diğerlerinde Finder'ın kendi metni (`errs`) korunur.
    static func mapError(code: Int, message: String?) -> FinderRecycleError {
        switch code {
        case Int(userCanceledErr): // -128
            return .userCancelled
        case Int(errAEEventNotPermitted): // -1743
            return .automationDenied
        case Int(errAEEventWouldRequireUserConsent): // -1744
            return .automationConsentRequired
        case Int(errAEWaitCanceled): // -1711
            return .waitCancelled
        case Int(errAETimeout): // -1712
            return .timedOut
        case Int(procNotFound), Int(connectionInvalid): // -600, -609
            return .finderUnavailable
        default:
            let m = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .finderFailed(code: code, message: m?.isEmpty == false ? m : nil)
        }
    }

    /// Gönderim sırasında atılan hatayı eşler (NSAppleEventDescriptor `NSOSStatusErrorDomain` ile atar). Hata
    /// metni yalnız gerçek bir açıklama varsa alınır (Cocoa'nın genel "işlem tamamlanamadı" metni değil).
    static func mapThrown(_ error: any Error) -> FinderRecycleError {
        if let e = error as? FinderRecycleError { return e }
        let ns = error as NSError
        return mapError(code: ns.code, message: thrownMessage(ns))
    }

    /// Atılan hatadaki Finder/Apple Event açıklaması (`errs` karşılığı); yoksa nil.
    static func thrownMessage(_ ns: NSError, depth: Int = 0) -> String? {
        for k in [NSLocalizedFailureReasonErrorKey, "NSAppleScriptErrorMessage", "NSAppleEventErrorString"] {
            if let m = ns.userInfo[k] as? String, !m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return m }
        }
        if depth < 3, let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return thrownMessage(under, depth: depth + 1)
        }
        return nil
    }

    /// Yol (sembolik bağ izlenmeden) hâlâ var mı.
    static func itemExists(at url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    // MARK: - Gerçek gönderim (testte çağrılmaz)

    private static let sendBatchDeleteEvent: BatchSender = { urls, timeout in
        let event = makeDeleteEvent(for: urls)
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: timeout)
        } catch {
            let e = mapThrown(error)
            TrashLog.logger.error("Finder toplu olay gönderilemedi: kod \(e.code ?? 0, privacy: .public), \(e.logText, privacy: .public)")
            throw e
        }
        if let error = replyError(reply) {
            TrashLog.logger.error("Finder toplu yanıt hatası: errn \(error.code ?? 0, privacy: .public), errs \(error.finderMessage ?? "-", privacy: .public)")
            throw error
        }
    }

    private static let sendDeleteEvent: Sender = { url, timeout in
        let event = makeDeleteEvent(for: url)
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: timeout)
        } catch {
            let e = mapThrown(error)
            TrashLog.logger.error("Finder olayı gönderilemedi: kod \(e.code ?? 0, privacy: .public), \(e.logText, privacy: .public)")
            throw e
        }
        if let error = replyError(reply) {
            TrashLog.logger.error("Finder yanıt hatası: errn \(error.code ?? 0, privacy: .public), errs \(error.finderMessage ?? "-", privacy: .public)")
            throw error
        }
        return resultingURL(from: reply)
    }
}

/// Finder ile taşıma hataları (Türkçe, `Trasher` raporunda gösterilir).
public enum FinderRecycleError: Error, Equatable, LocalizedError, Sendable {
    case userCancelled
    case automationDenied
    /// -1744: olay kullanıcı onayı gerektiriyor (Otomasyon izni henüz sorulmadı/verilmedi).
    case automationConsentRequired
    /// -1711: yanıt beklenirken bekleme iptal edildi.
    case waitCancelled
    case timedOut
    case finderUnavailable
    case finderFailed(code: Int, message: String?)
    case stillExists
    /// Yedek tek öğeli olaydan önce yeniden doğrulamada reddedildi (öğe Finder'a gönderilmedi).
    case revalidationFailed(String)

    /// Apple Event / OSStatus hata kodu (biliniyorsa).
    public var code: Int? {
        switch self {
        case .userCancelled: -128
        case .automationDenied: -1743
        case .automationConsentRequired: -1744
        case .waitCancelled: -1711
        case .timedOut: -1712
        case .finderUnavailable: -600
        case .finderFailed(let code, _): code
        case .stillExists, .revalidationFailed: nil
        }
    }

    /// Finder'ın kendi hata metni (`errs`), varsa.
    public var finderMessage: String? {
        if case .finderFailed(_, let m) = self { return m }
        return nil
    }

    /// Günlük için kısa metin.
    var logText: String { errorDescription ?? "\(self)" }

    public var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "yetki penceresi iptal edildi; öğe taşınmadı"
        case .automationDenied:
            return "Cleaner'ın Finder'ı kullanma izni yok. Sistem Ayarları → Gizlilik ve Güvenlik → Otomasyon → "
                + "Cleaner → Finder iznini açıp yeniden deneyin"
        case .automationConsentRequired:
            return "Cleaner'ın Finder'ı kullanması için onayınız gerekiyor (izin penceresi gösterilemedi). Sistem Ayarları → "
                + "Gizlilik ve Güvenlik → Otomasyon → Cleaner → Finder iznini açıp yeniden deneyin"
        case .waitCancelled:
            return "Finder'ın yanıtı beklenirken işlem iptal edildi; öğe taşınmamış olabilir, yeniden tarayın"
        case .timedOut:
            return "Finder zamanında yanıt vermedi (zaman aşımı); öğe taşınmamış olabilir, yeniden tarayın"
        case .finderUnavailable:
            return "Finder'a ulaşılamadı; Finder'ın açık olduğundan emin olup yeniden deneyin"
        case let .finderFailed(code, message):
            let base = Self.knownText(code) ?? "Finder taşıyamadı (hata \(code))"
            if let message { return "\(base). Finder'ın mesajı: \(message)" }
            return base
        case .stillExists:
            return "Finder işlemi bitirdi ama öğe hâlâ yerinde; taşınmış sayılmadı"
        case .revalidationFailed(let reason):
            return "yeniden denemeden önceki denetimde reddedildi: \(reason)"
        }
    }

    /// Bilinen Finder/Apple Event kodları için sade Türkçe metin.
    static func knownText(_ code: Int) -> String? {
        switch code {
        case -10000: // errAEEventFailed
            "Finder taşıyamadı (hata -10000): Finder işlemi reddetti; çoğunlukla izin ya da macOS koruması"
        case -5000: // afpAccessDenied
            "Finder taşıyamadı (hata -5000): erişim reddedildi"
        case -54, -61: // permErr, wrPermErr
            "Finder taşıyamadı (hata \(code)): yazma izni yok"
        case -1728, -43: // errAENoSuchObject, fnfErr
            "Finder öğeyi bulamadı (hata \(code)); taşınmış ya da silinmiş olabilir, yeniden tarayın"
        case -47: // fBsyErr
            "Finder taşıyamadı (hata -47): öğe kullanımda"
        case -1708, -1700: // errAEEventNotHandled, errAECoercionFail
            "Finder isteği anlamadı (hata \(code))"
        default:
            nil
        }
    }
}
