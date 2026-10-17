import CleanerAppCore
import CleanerKit
import SwiftUI

struct ScanningView: View {
    let progress: ScanProgressState

    var body: some View {
        Scroller {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 30) { RadarView(progress: progress); list }
                VStack(spacing: 20) { RadarView(progress: progress); list }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diskin taranıyor").font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Kurallar ve kullanım sinyalleri kontrol ediliyor. Hiçbir şey değiştirilmiyor.")
                .foregroundStyle(Theme.fg2).padding(.bottom, 6)
            ForEach(CategoryInfo.all) { info in
                let st = progress.status(info.category)
                HStack(spacing: 10) {
                    statusIcon(st).frame(width: 16)
                    CategoryTile(tint: Theme.tint(info.category), symbol: info.symbol, size: 22)
                    Text(info.title)
                    Spacer(minLength: 8)
                    Text(value(st)).foregroundStyle(Theme.fg2).monospacedDigit()
                }
                .opacity(st == .pending ? 0.4 : 1)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    @ViewBuilder private func statusIcon(_ st: ScanProgressState.Status) -> some View {
        switch st {
        case .pending: Circle().strokeBorder(Theme.line, lineWidth: 1.5).frame(width: 11, height: 11)
        case .running: ProgressView().controlSize(.small).scaleEffect(0.6)
        case .done: Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.ok)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
        }
    }

    private func value(_ st: ScanProgressState.Status) -> String {
        switch st {
        case .done(let n, let b): n == 0 && b == 0 ? "—" : Fmt.bytes(b)
        case .failed: "hata"
        default: ""
        }
    }
}

struct RadarView: View {
    let progress: ScanProgressState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let size: CGFloat = 230

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let angle = reduceMotion ? 0 : (t.truncatingRemainder(dividingBy: 1.6) / 1.6) * 360
            ZStack {
                Circle().fill(Theme.accent.opacity(0.07))
                ForEach(1..<5) { i in
                    Circle().strokeBorder(Theme.line, lineWidth: 1).frame(width: size * CGFloat(i) / 4, height: size * CGFloat(i) / 4)
                }
                Circle().fill(AngularGradient(stops: [
                    .init(color: .clear, location: 0), .init(color: .clear, location: 0.7),
                    .init(color: Theme.accent.opacity(0.12), location: 0.88), .init(color: Theme.accent.opacity(0.45), location: 1),
                ], center: .center))
                    .rotationEffect(.degrees(angle))
                ForEach(Array(CategoryInfo.all.enumerated()), id: \.offset) { i, info in
                    if case .done = progress.status(info.category) {
                        let a = Double(i) * 2.399963 // altın açı: dağınık ama sabit
                        let r = 0.28 + 0.2 * Double((i * 5) % 7) / 6
                        Circle().fill(Theme.tint(info.category)).frame(width: 9, height: 9)
                            .offset(x: cos(a) * r * size, y: sin(a) * r * size)
                    }
                }
                VStack(spacing: 0) {
                    Text("\(Int((progress.fraction * 100).rounded()))%")
                        .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("taranıyor").font(.system(size: 11.5)).foregroundStyle(Theme.fg2)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
        }
        .frame(width: size, height: size)
    }
}
