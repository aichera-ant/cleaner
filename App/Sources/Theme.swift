import AppKit
import CleanerKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

enum Theme {
    static let accent = Color(light: 0x0a64d6, dark: 0x3d8cff)
    static let ok = Color(light: 0x1c8a4a, dark: 0x3cc474)
    static let warn = Color(light: 0xa65f00, dark: 0xf2a93b)
    static let bad = Color(light: 0xc2352a, dark: 0xff6b5f)
    static let mute = Color(light: 0x67696f, dark: 0xa3a5ab)
    static let panel = Color(light: 0xffffff, dark: 0x26272a)
    static let window = Color(light: 0xf8f8f7, dark: 0x1d1e20)
    static let sidebar = Color(light: 0xeeeeea, dark: 0x262729)
    static let line = Color.primary.opacity(0.10)
    static let line2 = Color.primary.opacity(0.06)
    static let hover = Color.primary.opacity(0.045)
    static let fg2 = Color.secondary
    static let fg3 = Color.secondary.opacity(0.7)

    static func tint(_ c: ItemCategory) -> Color {
        switch c {
        case .xcode: Color(hex: 0x2f7de1)
        case .projectArtifacts: Color(hex: 0x2a9a6a)
        case .caches: Color(hex: 0xd49a12)
        case .docker: Color(hex: 0x1597ad)
        case .oldVersions: Color(hex: 0x7b8090)
        case .largeOld: Color(hex: 0xd0613f)
        case .duplicates: Color(hex: 0xbf4596)
        case .folders: Color(hex: 0x5f8f35)
        case .apps: Color(hex: 0x6c5ce0)
        }
    }

    static let overviewTint = Color(hex: 0x4a4d55)
    static let otherUsed = Color.primary.opacity(0.16)

    static func riskColor(_ item: CleanItem) -> Color {
        if item.isLocked { return mute }
        switch item.risk {
        case .green: return ok
        case .yellow: return warn
        case .red: return bad
        case .locked, .info: return mute
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: 1)
    }
}

private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// PNG çizimi: yerel malzeme (blur) yerine düz renk kullanılır.
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}
