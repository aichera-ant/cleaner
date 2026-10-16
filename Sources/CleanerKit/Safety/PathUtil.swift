import Darwin
import Foundation

/// Yol karşılaştırma yardımcıları. Koruma kontrolleri her zaman bunlarla yapılır.
enum PathUtil {
    /// Üst klasörün sembolik bağlantıları `realpath` ile çözülür, son bileşen olduğu gibi kalır.
    /// (Taşınan şey son bileşenin kendisidir; o bir bağlantıysa bağlantı taşınır, hedefi değil.)
    /// Üst klasör yoksa var olan en yakın ata çözülür, kalan bileşenler eklenir.
    static func canonical(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path == "/" { return "/" }
        let parent = (path as NSString).deletingLastPathComponent
        let last = (path as NSString).lastPathComponent
        let resolvedParent = resolveExistingPrefix(parent)
        return resolvedParent == "/" ? "/" + last : resolvedParent + "/" + last
    }

    /// Var olan en uzun önek `realpath` ile çözülür, var olmayan kuyruk aynen eklenir.
    static func resolveExistingPrefix(_ path: String) -> String {
        var head = path
        var tail: [String] = []
        while true {
            if let r = realPath(head) {
                guard !tail.isEmpty else { return r }
                return (r == "/" ? "" : r) + "/" + tail.reversed().joined(separator: "/")
            }
            if head == "/" || head.isEmpty { return path }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
    }

    /// Klasörün kendisi dahil tamamen çözülmüş yol (kökler için: home vb.).
    static func canonicalDirectory(_ url: URL) -> String {
        resolveExistingPrefix(url.standardizedFileURL.path)
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Büyük/küçük harf duyarsız (APFS varsayılanı) karşılaştırma için anahtar.
    static func key(_ path: String) -> String {
        var p = path.lowercased()
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// `path`, `ancestor` ile aynı ya da onun altında mı? (ikisi de `key` biçiminde)
    static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        if path == ancestor { return true }
        let prefix = ancestor == "/" ? "/" : ancestor + "/"
        return path.hasPrefix(prefix)
    }
}
