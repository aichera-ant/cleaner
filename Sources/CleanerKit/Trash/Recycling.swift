import AppKit
import Foundation

/// Bir yolu Çöp Kutusu'na taşır. Kalıcı silme yapmaz.
public protocol Recycling: Sendable {
    /// Yolu Çöp Kutusu'na taşır; Çöp Kutusu'ndaki yeni konumu döner (bilinmiyorsa nil).
    func recycle(_ url: URL) async throws -> URL?
    /// Birden çok yolu tek seferde taşır (yetkili taşıyıcıda tek parola). Sonuç her verilen URL için
    /// (verildiği haliyle anahtar) başarı (Çöp Kutusu'ndaki konum, bilinmiyorsa nil) ya da hata.
    func recycle(_ urls: [URL]) async -> [URL: Result<URL?, any Error>]
    /// Toplu taşıma; ilk denemeden SONRA yapılan her ek deneme (ör. Finder'ın tek öğeli yedek olayı) öncesinde
    /// `revalidate` çağrılır: nil değilse dönen neden ret nedenidir, öğe yeniden denenmez.
    func recycle(_ urls: [URL], revalidate: @escaping @Sendable (URL) -> String?) async -> [URL: Result<URL?, any Error>]
}

extension Recycling {
    /// Varsayılan: tek tek taşır.
    public func recycle(_ urls: [URL]) async -> [URL: Result<URL?, any Error>] {
        var out: [URL: Result<URL?, any Error>] = [:]
        for u in urls {
            do { out[u] = .success(try await recycle(u)) } catch { out[u] = .failure(error) }
        }
        return out
    }

    /// Varsayılan: ek deneme yapılmaz, `recycle(_: [URL])`'e verilir (yeniden doğrulama gerekmez).
    public func recycle(_ urls: [URL], revalidate: @escaping @Sendable (URL) -> String?) async
        -> [URL: Result<URL?, any Error>] {
        await recycle(urls)
    }
}

/// `FileManager.trashItem`: kullanıcı yetkisiyle taşır, yetki istemez. Varsayılan taşıyıcı.
public struct FileManagerRecycler: Recycling {
    public init() {}

    public func recycle(_ url: URL) async throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}

/// `NSWorkspace.recycle`. ARTIK ARAYÜZDE KULLANILMAZ: root sahipli paketlerde (ör. `/Applications/Microsoft Word.app`)
/// yetki istemeden "izin yok" hatası verdiği görüldü; yerine `FinderRecycler` kullanılır.
/// Önceki niyet: Finder gibi taşır; macOS Uygulama Yönetimi koruması ya da root sahipliği varsa
/// kullanıcıdan parola/Touch ID ister. YALNIZ `Trasher`'ın yetkili taşıyıcısı olarak, taze taramada
/// `needsAuthorization` olan ve dar uygulama istisnasını taşıma anında yeniden geçen `.app` paketi için kullanılır.
/// CLI bunu vermez. Testte çağrılmaz.
public struct WorkspaceRecycler: Recycling {
    public init() {}

    public func recycle(_ url: URL) async throws -> URL? {
        let result = try await Self.recycleOnMain(url)
        return Self.resultingURL(for: url, in: result)
    }

    /// Sonuç sözlüğünde bu URL'nin karşılığı (standardize/resolve edilmiş eşleşme dahil); yoksa nil.
    /// Başka bir öğenin konumuna asla düşmez.
    static func resultingURL(for url: URL, in result: [URL: URL]) -> URL? {
        if let r = result[url] ?? result[url.standardizedFileURL] { return r }
        let keys = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
        for (k, v) in result {
            let kp = [k.standardizedFileURL.path, k.resolvingSymlinksInPath().path]
            if keys.contains(where: kp.contains) { return v }
        }
        return nil
    }

    /// AppKit çağrısı ana aktörde yapılır (yetki penceresi arayüze bağlıdır).
    @MainActor
    private static func recycleOnMain(_ url: URL) async throws -> [URL: URL] {
        try await NSWorkspace.shared.recycle([url])
    }
}

/// Kapanışla taşıyan (test ve iç kullanım).
struct ClosureRecycler: Recycling {
    let body: @Sendable (URL) throws -> URL?

    func recycle(_ url: URL) async throws -> URL? { try body(url) }
}
