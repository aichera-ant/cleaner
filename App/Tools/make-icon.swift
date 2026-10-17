// Uygulama simgesi üretici: `swift App/Tools/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset`
// Yeşil-turkuaz degrade zemin üzerinde beyaz süpürge/parıltı (SF Symbol "sparkles").
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

func render(px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.06
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.89, blue: 0.71, alpha: 1),
                        NSColor(srgbRed: 0.09, green: 0.64, blue: 0.54, alpha: 1),
                        NSColor(srgbRed: 0.04, green: 0.43, blue: 0.47, alpha: 1)])!.draw(in: path, angle: -60)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let w = tinted.size.width, h = tinted.size.height
        tinted.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for (pt, scale) in sizes {
    let name = "icon_\(pt)x\(pt)@\(scale)x.png"
    try! render(px: pt * scale).write(to: URL(fileURLWithPath: out + "/" + name))
    images.append("{\"filename\":\"\(name)\",\"idiom\":\"mac\",\"scale\":\"\(scale)x\",\"size\":\"\(pt)x\(pt)\"}")
}
let json = "{\"images\":[" + images.joined(separator: ",") + "],\"info\":{\"author\":\"xcode\",\"version\":1}}"
try! json.write(toFile: out + "/Contents.json", atomically: true, encoding: .utf8)
