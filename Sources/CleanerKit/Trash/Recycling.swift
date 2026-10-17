import AppKit
import Foundation

/// Bir yolu Çöp Kutusu'na taşır. Kalıcı silme yapmaz.
public protocol Recycling: Sendable {
    /// Yolu Çöp Kutusu'na taşır; Çöp Kutusu'ndaki yeni konumu döner (bilinmiyorsa nil).
    func recycle(_ url: URL) async throws -> URL?
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

/// `NSWorkspace.recycle`: Finder gibi taşır; macOS Uygulama Yönetimi koruması ya da root sahipliği varsa
/// kullanıcıdan parola/Touch ID ister. YALNIZ `Trasher`'ın yetkili taşıyıcısı olarak, taze taramada
/// `needsAuthorization` olan ve dar uygulama istisnasını taşıma anında yeniden geçen `.app` paketi için kullanılır.
/// CLI bunu vermez. Testte çağrılmaz.
public struct WorkspaceRecycler: Recycling {
    public init() {}

    public func recycle(_ url: URL) async throws -> URL? {
        let result = try await Self.recycleOnMain(url)
        return result[url] ?? result[url.standardizedFileURL] ?? result.values.first
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
