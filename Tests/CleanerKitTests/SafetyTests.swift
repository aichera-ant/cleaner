import CryptoKit
import Foundation
import Testing
@testable import CleanerKit

@Suite("Bulut koruması ve güvenli okuma")
struct CloudGuardTests {
    func probes(dataless: Set<String> = [], notCurrent: Set<String> = []) -> CloudGuard.Probes {
        CloudGuard.Probes(
            isDataless: { dataless.contains($0.path) },
            isDownloadedCurrent: { notCurrent.contains($0.path) ? false : nil },
            isRegularFile: CloudGuard.Probes.live.isRegularFile
        )
    }

    @Test("dataless dosya okunmaya çalışılınca okuma yapılmaz")
    func datalessIsNeverOpened() throws {
        let t = try TempTree()
        let f = try t.file("Desktop/yedek/video.gif", bytes: 10_000)
        let opened = Counter()
        let reader = SafeReader(
            cloudGuard: CloudGuard(home: t.home, probes: probes(dataless: [f.path])),
            willOpen: { opened.hit($0.path) }
        )
        #expect(throws: SafeReader.ReadError.self) { _ = try reader.readPrefix(f, bytes: 1024) }
        #expect(throws: SafeReader.ReadError.self) { _ = try reader.sha256(f) }
        #expect(throws: SafeReader.ReadError.self) { _ = try reader.sha256Prefix(f, bytes: 1 << 20) }
        #expect(opened.n == 0, "dataless dosya açılmamalıydı")
        do {
            _ = try reader.readPrefix(f, bytes: 1)
            Issue.record("hata bekleniyordu")
        } catch {
            guard case .rejected(.dataless) = error else { Issue.record("yanlış hata: \(error)"); return }
        }
    }

    @Test("indirilmemiş iCloud dosyası okunmaz")
    func notDownloadedIsNeverOpened() throws {
        let t = try TempTree()
        let f = try t.file("Documents/a.pdf")
        let opened = Counter()
        let reader = SafeReader(
            cloudGuard: CloudGuard(home: t.home, probes: probes(notCurrent: [f.path])),
            willOpen: { opened.hit($0.path) }
        )
        #expect(throws: SafeReader.ReadError.self) { _ = try reader.sha256(f) }
        #expect(opened.n == 0)
    }

    @Test("iCloud ve CloudStorage altı varsayılan kapalı")
    func cloudRootsBlockedByDefault() throws {
        let t = try TempTree()
        let icloud = try t.file("Library/Mobile Documents/com~apple~CloudDocs/x.txt")
        let drive = try t.file("Library/CloudStorage/GoogleDrive-a/y.txt")
        let opened = Counter()
        let reader = SafeReader(cloudGuard: CloudGuard(home: t.home), willOpen: { opened.hit($0.path) })
        for f in [icloud, drive] {
            #expect(throws: SafeReader.ReadError.self) { _ = try reader.readPrefix(f, bytes: 10) }
        }
        #expect(opened.n == 0)
        #expect(CloudGuard(home: t.home).isUnderCloudRoot(icloud))
        // Büyük/küçük harf farkı korumayı aşmaz.
        let odd = t.home.appending(path: "library/mobile documents/z")
        #expect(CloudGuard(home: t.home).isUnderCloudRoot(odd))
    }

    @Test("sembolik bağlantı ve klasör okunmaz")
    func symlinkAndDirectoryRejected() throws {
        let t = try TempTree()
        let target = try t.file("real.bin")
        let link = t.home.appending(path: "link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let reader = SafeReader(cloudGuard: CloudGuard(home: t.home))
        #expect(throws: SafeReader.ReadError.self) { _ = try reader.readPrefix(link, bytes: 10) }
        #expect(throws: SafeReader.ReadError.self) { _ = try reader.readPrefix(t.home, bytes: 10) }
    }

    @Test("normal dosya okunur, özet doğru")
    func normalFileReads() throws {
        let t = try TempTree()
        let f = t.home.appending(path: "a.txt")
        let content = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try content.write(to: f)
        let reader = SafeReader(cloudGuard: CloudGuard(home: t.home))
        #expect(try reader.readPrefix(f, bytes: 5) == content.prefix(5))
        let expected = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        #expect(try reader.sha256(f) == expected)
        let expectedPrefix = SHA256.hash(data: content.prefix(1 << 20)).map { String(format: "%02x", $0) }.joined()
        #expect(try reader.sha256Prefix(f, bytes: 1 << 20) == expectedPrefix)
    }

    @Test("gerçek dosyada SF_DATALESS bayrağı yok")
    func liveFlagFalseForLocalFile() throws {
        let t = try TempTree()
        let f = try t.file("x")
        #expect(!CloudGuard.hasDatalessFlag(path: f.path))
        #expect(CloudGuard.disableDatalessMaterializationForProcess())
    }
}

@Suite("İçerik okuma kuralı")
struct SafeReaderPolicyTests {
    /// `Sources/` altında içerik okuyan API yalnız `SafeReader.swift`'te (ve paket kaynağı için `Rule.swift`'te) olabilir.
    @Test("SafeReader dışında içerik okuyan kod yok")
    func noRawReadsOutsideSafeReader() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sources = testsDir.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources")
        let forbidden = [
            "Data(contentsOf", "String(contentsOf", "contentsOfFile", "FileHandle(forReading",
            "FileHandle(forUpdating", "InputStream(", "fopen(", "mmap(", "Darwin.open(", " open(", "\topen(",
            "readDataToEndOfFile", "readToEnd(", ".read(upToCount",
        ]
        let allowed: [String: Set<String>] = [
            "SafeReader.swift": [" open("],
            "Rule.swift": ["Data(contentsOf"], // yalnız kendi paket kaynağımız rules.json
            "CommandRunner.swift": ["readDataToEndOfFile"], // yalnız alt süreç borusu
        ]
        var violations: [String] = []
        let e = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var checked = 0
        while let u = e?.nextObject() as? URL {
            guard u.pathExtension == "swift" else { continue }
            checked += 1
            let text = try String(contentsOf: u, encoding: .utf8)
            for pattern in forbidden where text.contains(pattern) {
                if allowed[u.lastPathComponent]?.contains(pattern) == true { continue }
                violations.append("\(u.lastPathComponent): \(pattern)")
            }
        }
        #expect(checked > 5)
        #expect(violations.isEmpty, "İçerik okuma SafeReader'dan geçmeli: \(violations)")
    }
}

@Suite("Korunan yollar")
struct PathPolicyTests {
    @Test("korunan yollar asla öğe olamaz")
    func protectedPaths() throws {
        let t = try TempTree()
        let p = PathPolicy(home: t.home)
        let protected = [
            t.home, t.home.appending(path: "Documents"), t.home.appending(path: "Desktop"),
            t.home.appending(path: "Library"), t.home.appending(path: "Library/Caches"),
            t.home.appending(path: "Library/Mobile Documents"),
            t.home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/Desktop"),
            t.home.appending(path: "Library/CloudStorage/Dropbox/a"),
            t.home.appending(path: "Library/Keychains/login.keychain-db"),
            t.home.appending(path: ".ssh"), t.home.appending(path: ".ssh/id_ed25519"),
            t.home.appending(path: ".gnupg/pubring.kbx"),
            t.home.appending(path: "Documents/projeler/x/.git"),
            t.home.appending(path: "Documents/projeler/x/.git/objects/ab"),
            t.home.appending(path: "DOCUMENTS"), // büyük/küçük harf
            t.home.appending(path: "Documents/../Documents"), // standartlaştırma
            URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/System/Library"),
            URL(fileURLWithPath: "/usr/local/bin"), URL(fileURLWithPath: "/Library/Caches"),
            URL(fileURLWithPath: "/Applications"),
        ]
        for u in protected {
            #expect(p.protectionReason(for: u) != nil, "korunmalıydı: \(u.path)")
            #expect(p.trashRejectionReason(for: u) != nil, "taşınmamalıydı: \(u.path)")
        }
    }

    @Test("sıradan yollar öğe olabilir")
    func allowedPaths() throws {
        let t = try TempTree()
        let p = PathPolicy(home: t.home)
        let ok = [
            t.home.appending(path: "Library/Caches/Google"),
            t.home.appending(path: "Documents/projeler/x/node_modules"),
            t.home.appending(path: "Desktop/proje/.next"),
            t.home.appending(path: ".npm"),
            URL(fileURLWithPath: "/Applications/Foo.app"), // listelenebilir, taşınamaz
        ]
        for u in ok { #expect(p.protectionReason(for: u) == nil, "izinli olmalıydı: \(u.path)") }
    }

    @Test("ana klasör dışı, git kökü ve olmayan yol taşınamaz")
    func trashRejections() throws {
        let t = try TempTree()
        let p = PathPolicy(home: t.home)
        let outside = try t.file("outside.bin", in: t.root)
        #expect(p.trashRejectionReason(for: outside) != nil)
        #expect(!p.isInsideHome(outside))
        let repo = try t.dir("Documents/projeler/repo")
        try t.dir(".git", in: repo)
        #expect(p.trashRejectionReason(for: repo)?.contains("git") == true)
        #expect(p.trashRejectionReason(for: t.home.appending(path: "yok")) == "yol yok")
        let fine = try t.file("Library/Caches/x/a.bin")
        #expect(p.trashRejectionReason(for: fine.deletingLastPathComponent()) == nil)
        // Ana klasör içinden dışarı giden bağlantı ile üst klasör aşılamaz.
        let linkDir = t.home.appending(path: "kacis")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: t.root)
        #expect(p.trashRejectionReason(for: linkDir.appending(path: "outside.bin")) != nil)
        #expect(!p.isInsideHome(linkDir.appending(path: "outside.bin")))
        // Ana klasörün korunan klasörüne giden bağlantının içi de korunur.
        let sshLink = t.home.appending(path: "anahtarlar")
        try t.dir(".ssh")
        try t.file(".ssh/id")
        try FileManager.default.createSymbolicLink(at: sshLink, withDestinationURL: t.home.appending(path: ".ssh"))
        #expect(p.trashRejectionReason(for: sshLink.appending(path: "id")) != nil)
    }
}
