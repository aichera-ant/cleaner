import CryptoKit
import Darwin
import Foundation

/// Dosya içeriği okumanın TEK yolu. Hash, mükerrer, içerik incelemesi ... hepsi buradan geçer.
///
/// Her okumadan önce `CloudGuard.checkContentReadable` çağrılır; dosya açıldıktan sonra `fstat` ile
/// `SF_DATALESS` bir kez daha denetlenir (kontrol ile açma arasındaki yarışa karşı). Dosya
/// `O_NOFOLLOW` ile açılır; sembolik bağlantı okunmaz.
///
/// Kural: `Sources/` altında `SafeReader.swift` dışında dosya içeriği okuyan kod yazılmaz
/// (`SafeReaderPolicyTests` bunu denetler).
public struct SafeReader: Sendable {
    public enum ReadError: Error, CustomStringConvertible, Sendable {
        case rejected(CloudGuard.Rejection)
        case io(String, Int32)

        public var description: String {
            switch self {
            case .rejected(let r): r.description
            case .io(let p, let e): "okuma hatası (\(e)): \(p)"
            }
        }
    }

    public let cloudGuard: CloudGuard
    /// Test kancası: gerçek açma işleminden hemen önce çağrılır. Testler "okuma yapılmadı"yı bununla doğrular.
    let willOpen: (@Sendable (URL) -> Void)?

    public init(cloudGuard: CloudGuard) {
        self.cloudGuard = cloudGuard
        self.willOpen = nil
    }

    init(cloudGuard: CloudGuard, willOpen: @escaping @Sendable (URL) -> Void) {
        self.cloudGuard = cloudGuard
        self.willOpen = willOpen
    }

    /// İlk `bytes` baytı okur.
    public func readPrefix(_ url: URL, bytes: Int) throws(ReadError) -> Data {
        var result = Data()
        try withOpenFile(url) { fd throws(ReadError) in
            result = try readLoop(fd: fd, path: url.path, limit: bytes) { _ in }
        }
        return result
    }

    /// Dosyanın tamamının SHA-256 özeti (hex). Bellekte tutmadan parça parça okur.
    public func sha256(_ url: URL) throws(ReadError) -> String {
        var hasher = SHA256()
        try withOpenFile(url) { fd throws(ReadError) in
            _ = try readLoop(fd: fd, path: url.path, limit: nil) { chunk in hasher.update(data: chunk) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// İlk `bytes` baytın SHA-256 özeti (mükerrer taramasının ikinci kademesi).
    public func sha256Prefix(_ url: URL, bytes: Int) throws(ReadError) -> String {
        let data = try readPrefix(url, bytes: bytes)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - İç

    private func withOpenFile(_ url: URL, _ body: (Int32) throws(ReadError) -> Void) throws(ReadError) {
        do { try cloudGuard.checkContentReadable(url) } catch { throw .rejected(error) }
        CloudGuard.disableDatalessMaterializationForProcess()
        willOpen?(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw .io(url.path, errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw .io(url.path, errno) }
        if (st.st_flags & UInt32(SF_DATALESS)) != 0 { throw .rejected(.dataless(url.path)) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw .rejected(.notRegularFile(url.path)) }
        try body(fd)
    }

    private func readLoop(fd: Int32, path: String, limit: Int?, onChunk: (Data) -> Void) throws(ReadError) -> Data {
        let chunkSize = 1 << 20
        var collected = Data()
        var remaining = limit ?? Int.max
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while remaining > 0 {
            let want = min(chunkSize, remaining)
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, want) }
            if n < 0 {
                if errno == EINTR { continue }
                throw .io(path, errno)
            }
            if n == 0 { break }
            let chunk = Data(buffer[0..<n])
            if limit != nil { collected.append(chunk) }
            onChunk(chunk)
            remaining -= n
        }
        return collected
    }
}
