// Uygulama simgesi üretici (SVG'den):
//   swift App/Tools/make-icon.swift App/Resources/Logo/hepp-cleaner-a.svg App/Resources/Assets.xcassets/AppIcon.appiconset
// Logo SVG'si (viewBox 120, yuvarlatılmış kare 2..118) macOS simge kılavuzuna göre 1024 tuvalde ~824 px kareye oturtulur.
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let svg = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write(Data("kullanım: make-icon.swift <logo.svg> <AppIcon.appiconset>\n".utf8))
    exit(1)
}
let out = args[2]
let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
/// SVG'deki kare 116/120 oranında; 824/1024 hedefi için görüntü tuvalin bu oranı kadarı olur.
let imageScale = (824.0 / 1024.0) * (120.0 / 116.0)

func render(px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let side = s * imageScale
    svg.draw(in: NSRect(x: (s - side) / 2, y: (s - side) / 2, width: side, height: side))
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
