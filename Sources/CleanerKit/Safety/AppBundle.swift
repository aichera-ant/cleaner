import Darwin
import Foundation

/// Bir `.app` paketinin kimlik bilgisi. Info.plist yalnız `SafeReader` ile okunur.
public struct AppBundleInfo: Sendable, Equatable {
    public var bundleID: String
    /// Finder'da görünen ad (paket adı, `.app` olmadan).
    public var name: String
    public var version: String?
    /// App Store'dan kurulmuş (`Contents/_MASReceipt`).
    public var isAppStore: Bool
    /// Kendi kaldırıcısı önerilir: paket sistem/ağ uzantısı, giriş öğesi ya da ayrıcalıklı yardımcı taşıyor.
    public var uninstallerHints: [String]
    /// Info.plist'teki `CFBundleDisplayName`, `CFBundleName` ve `CFBundleExecutable` (ad tabanlı artık eşleşmesi için).
    public var displayName: String?
    public var bundleName: String?
    public var executableName: String?

    public init(bundleID: String, name: String, version: String?, isAppStore: Bool, uninstallerHints: [String],
                displayName: String? = nil, bundleName: String? = nil, executableName: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.isAppStore = isAppStore
        self.uninstallerHints = uninstallerHints
        self.displayName = displayName
        self.bundleName = bundleName
        self.executableName = executableName
    }

    /// Uygulamanın bütün normalize adları (paket adı, görünen ad, `CFBundleName`, çalıştırılabilir ad); süzülmemiş.
    /// Çakışma denetiminde kullanılır (genel adlar dahil: başka uygulamayla çakışma ne kadar geniş o kadar güvenli).
    public var allNameKeys: Set<String> {
        Set([name, displayName, bundleName, executableName].compactMap { $0 }.map(LeftoverNames.normalize).filter { !$0.isEmpty })
    }

    /// Ad tabanlı artık aramasında kullanılabilecek adlar (paket adı, görünen ad, `CFBundleName`): en az 4 karakter,
    /// genel kelime değil. Çalıştırılabilir ad (`CFBundleExecutable`) aramada KULLANILMAZ (ör. Warp → "stable");
    /// yalnız çakışma denetimine (`allNameKeys`) girer.
    public var leftoverNameKeys: Set<String> {
        Set([name, displayName, bundleName].compactMap { $0 }.map(LeftoverNames.normalize).filter(LeftoverNames.isUsableKey))
    }

    /// Apple sistem uygulaması mı? (`com.apple.*`)
    public var isApple: Bool { AppBundleInfo.isAppleBundleID(bundleID) }

    public static func isAppleBundleID(_ id: String) -> Bool {
        let l = id.lowercased()
        return l == "com.apple" || l.hasPrefix("com.apple.")
    }

    /// Yol bileşeni olarak güvenli bundle id mi? (artık yolları bu kimlikten türetilir)
    public static func isValidBundleID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 255, id != ".", id != ".." else { return false }
        guard let first = id.unicodeScalars.first, CharacterSet.alphanumerics.contains(first), first.isASCII else {
            return false
        }
        return id.unicodeScalars.allSatisfy { s in
            s.isASCII && (CharacterSet.alphanumerics.contains(s) || s == "." || s == "-" || s == "_")
        }
    }

    static let maxPlistBytes = 1 << 20

    /// Kaldırıcı gerektirebilecek paket içerikleri (`Contents/` altına göreli).
    static let uninstallerMarkers = [
        "Library/SystemExtensions", "Library/LoginItems", "Library/LaunchServices",
        "Library/LaunchDaemons", "Library/LaunchAgents",
    ]

    /// Paketin Info.plist'i. iOS sarmalı uygulamalarda (`WrappedBundle`) iç paketinki; paket dışına çıkılmaz.
    static func infoPlistURL(_ bundle: URL) -> URL? {
        let fm = FileManager.default
        let contents = bundle.appending(path: "Contents/Info.plist")
        if fm.fileExists(atPath: contents.path) { return contents }
        let wrapped = bundle.appending(path: "WrappedBundle")
        guard let real = PathUtil.realPath(wrapped.path), let bundleReal = PathUtil.realPath(bundle.path),
              PathUtil.isSameOrDescendant(PathUtil.key(real), of: PathUtil.key(bundleReal)),
              PathUtil.key(real) != PathUtil.key(bundleReal)
        else { return nil }
        let inner = URL(fileURLWithPath: real).appending(path: "Info.plist")
        return fm.fileExists(atPath: inner.path) ? inner : nil
    }

    /// Yalnız bundle id (çalışan uygulama listesi için hafif okuma).
    static func readBundleID(_ bundle: URL, reader: SafeReader) -> String? {
        guard let plist = infoPlist(bundle, reader: reader),
              let id = plist["CFBundleIdentifier"] as? String, isValidBundleID(id)
        else { return nil }
        return id
    }

    static func infoPlist(_ bundle: URL, reader: SafeReader) -> [String: Any]? {
        guard let url = infoPlistURL(bundle),
              let data = try? reader.readPrefix(url, bytes: maxPlistBytes), data.count < maxPlistBytes,
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return nil }
        return obj as? [String: Any]
    }

    /// Paketi okur. Info.plist yoksa, okunamazsa ya da bundle id geçersizse nil.
    public static func read(_ bundle: URL, reader: SafeReader) -> AppBundleInfo? {
        guard let plist = infoPlist(bundle, reader: reader),
              let id = plist["CFBundleIdentifier"] as? String, isValidBundleID(id)
        else { return nil }
        let fm = FileManager.default
        var name = bundle.lastPathComponent
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        let version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String)
        let contents = bundle.appending(path: "Contents")
        let isMAS = fm.fileExists(atPath: contents.appending(path: "_MASReceipt").path)
        let hints = uninstallerMarkers.filter { fm.fileExists(atPath: contents.appending(path: $0).path) }
            .map { ($0 as NSString).lastPathComponent }
        func str(_ k: String) -> String? {
            guard let v = plist[k] as? String, !v.isEmpty, v.count <= 255 else { return nil }
            return v
        }
        return AppBundleInfo(bundleID: id, name: name, version: version, isAppStore: isMAS, uninstallerHints: hints,
                             displayName: str("CFBundleDisplayName"), bundleName: str("CFBundleName"),
                             executableName: str("CFBundleExecutable"))
    }
}

/// Çalışan uygulamalar: çalışan her sürecin yolundaki `.app` paketleri ve bunların bundle id'leri.
public struct RunningApps: Sendable {
    /// Çalışan bir çalıştırılabilir dosyayı içeren her `.app` paketinin yol anahtarı (küçük harf, çözülmüş).
    public private(set) var bundlePathKeys: Set<String> = []
    /// Bu paketlerin bundle id'leri (küçük harf).
    public private(set) var bundleIDs: Set<String> = []

    public init(processes: [RunningProcess], reader: SafeReader) {
        var bundles = Set<String>()
        for p in processes {
            guard let path = p.path, path.hasPrefix("/") else { continue }
            let resolved = PathUtil.canonical(URL(fileURLWithPath: path))
            var prefix = ""
            for comp in resolved.split(separator: "/") {
                prefix += "/" + comp
                if comp.lowercased().hasSuffix(".app") { bundles.insert(prefix) }
            }
        }
        bundlePathKeys = Set(bundles.map(PathUtil.key))
        for b in bundles {
            // Apple sistem paketleri zaten hiçbir zaman taşınmaz; okumaya gerek yok.
            if PathUtil.key(b).hasPrefix("/system/") { continue }
            if let id = AppBundleInfo.readBundleID(URL(fileURLWithPath: b), reader: reader) {
                bundleIDs.insert(id.lowercased())
            }
        }
    }

    /// Paket (yolu ya da bundle id'si ile) çalışıyor mu?
    public func isRunning(bundle: URL, bundleID: String?) -> Bool {
        if bundlePathKeys.contains(PathUtil.key(PathUtil.canonical(bundle))) { return true }
        if let bundleID, bundleIDs.contains(bundleID.lowercased()) { return true }
        return false
    }
}
