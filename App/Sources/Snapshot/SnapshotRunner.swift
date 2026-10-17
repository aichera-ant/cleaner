#if DEBUG
import AppKit
import CleanerAppCore
import CleanerKit
import SwiftUI

/// `--snapshot <klasör>`: ana ekranları sahte veriyle PNG'ye çizer ve çıkar. Gerçek tarama/taşıma yapılmaz.
@MainActor
enum SnapshotRunner {
    static func run(into dir: String) async {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for width in [1100, 800] {
            for name in ["ozet", "onbellekler", "mukerrer", "uygulamalar", "onizleme", "sonuc", "tarama"] {
                let (model, ui) = await prepare(name)
                render(RootView(model: model, ui: ui), width: width, to: "\(dir)/\(name)-\(width).png")
                model.cancelScan()
            }
        }
    }

    private static func prepare(_ name: String) async -> (AppModel, UIState) {
        let ui = UIState()
        if name == "tarama" {
            let model = AppModel(scanService: SampleScanService(neverFinish: true, progressUpTo: 4), trashService: SampleTrashService(),
                                 diskProvider: disk)
            Task { await model.startScan() }
            try? await Task.sleep(for: .milliseconds(300))
            return (model, ui)
        }
        let model = AppModel(scanService: SampleScanService(), trashService: SampleTrashService(), diskProvider: disk)
        await model.startScan()
        switch name {
        case "onbellekler":
            ui.section = .category(.caches)
            if let y = model.items.first(where: { $0.name.hasPrefix("Playwright") }) { model.selection.set(y, selected: true) }
        case "mukerrer":
            ui.section = .category(.duplicates)
            if let c = model.items.first(where: { $0.category == .duplicates && $0.path.contains("Desktop") }) { model.selection.keep(c) }
        case "uygulamalar":
            ui.section = .category(.apps)
            if let a = model.items.first(where: { $0.name == "Sketch" }) { model.selection.set(a, selected: true) }
        case "onizleme", "sonuc":
            if let y = model.items.first(where: { $0.name.hasPrefix("Playwright") }) { model.selection.set(y, selected: true) }
            if let y = model.items.first(where: { $0.name.hasPrefix("iOS 17.2") }) { model.selection.set(y, selected: true) }
            if case .plan(let p) = model.requestConfirm() {
                if name == "onizleme" { ui.sheet = .confirm(p) } else { await model.confirmMove(p) }
            }
        default: break
        }
        return (model, ui)
    }

    private static let disk: @Sendable () -> DiskInfo? = {
        DiskInfo(totalBytes: 494 * SampleData.GB, availableBytes: 52 * SampleData.GB)
    }

    private static func render(_ view: some View, width: Int, to path: String) {
        let content = view.environment(\.snapshotMode, true).frame(width: CGFloat(width), height: 720)
        let r = ImageRenderer(content: content)
        r.scale = 1
        guard let cg = r.cgImage else { print("çizilemedi: \(path)"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("yazıldı: \(path)")
        }
    }
}
#endif
