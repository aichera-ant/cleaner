#if canImport(AppKit)
import AppKit
import ApplicationServices
import Foundation

/// Canlı tespit. Hiçbir dosyanın içeriği okunmaz; başka uygulamaya işlem yapılmaz. Testte çağrılmaz.
public struct LivePermissionProbe: PermissionProbe {
    public init() {}

    /// Korumalı bir klasörün yalnız dosya adlarını listelemeyi dener (içerik okunmaz). İzin hatası -> reddedildi.
    public func fullDiskAccess() -> ProbeResult {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for dir in [home + "/Library/Safari", home + "/Library/Mail"] {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: dir)
                return .granted
            } catch {
                let ns = error as NSError
                let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError
                let posix = [ns, under].compactMap { $0 }.filter { $0.domain == NSPOSIXErrorDomain }.map(\.code)
                if ns.code == NSFileReadNoPermissionError || posix.contains(Int(EPERM)) || posix.contains(Int(EACCES)) { return .denied }
                // Klasör yoksa sonrakini dene.
            }
        }
        return .unknown
    }

    public func automation(askUser: Bool) -> ProbeResult {
        let bundleID = "com.apple.finder"
        var target = AEAddressDesc()
        let created = bundleID.withCString { ptr in
            AECreateDesc(DescType(typeApplicationBundleID), ptr, strlen(ptr), &target)
        }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUser)
        switch Int(status) {
        case 0: return .granted
        case -1743: return .denied            // errAEEventNotPermitted
        case -1744: return .notDetermined     // errAEEventWouldRequireUserConsent
        default: return .unknown              // -600 (Finder çalışmıyor) vb.
        }
    }
}
#endif
