import CleanerAppCore
import CleanerKit
import SwiftUI

struct OverviewView: View {
    let model: AppModel
    let ui: UIState

    private var totals: [ItemCategory: UInt64] { Summaries.totals(model.items) }

    var body: some View {
        Scroller {
            VStack(alignment: .leading, spacing: 22) {
                if model.resultsOutdated || model.errorMessage != nil { banners }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 28) { donut; hero }
                    VStack(alignment: .center, spacing: 18) { donut; hero }
                }
                if !(model.snapshot?.errors.isEmpty ?? true) {
                    Banner(symbol: "exclamationmark.triangle.fill", tint: Theme.warn,
                           text: Text("\(model.snapshot!.errors.count) tarayıcı hata verdi; o kategoriler eksik olabilir."))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                    ForEach(CategoryInfo.all) { info in card(info) }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 22)
        }
    }

    @ViewBuilder private var banners: some View {
        if model.resultsOutdated {
            Banner(symbol: "arrow.clockwise", text: Text("Taşımadan sonra bu liste güncel değil. Yeniden tara.")) {
                Button("Yeniden tara") { Task { await model.startScan() } }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var donut: some View {
        let disk = model.disk
        let total = Double(max(1, disk?.totalBytes ?? 1))
        var segs: [(Color, Double)] = []
        var cleanable = 0.0
        for info in CategoryInfo.all {
            let b = Double(totals[info.category] ?? 0)
            if b > 0 { segs.append((Theme.tint(info.category), b / total)); cleanable += b }
        }
        if let disk {
            let other = max(0, Double(disk.usedBytes) - cleanable)
            segs.append((Theme.otherUsed, other / total))
        }
        return Donut(segments: segs) {
            VStack(spacing: 3) {
                Text(disk.map { Fmt.bytes($0.availableBytes) } ?? "—")
                    .font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text("boş alan").font(.system(size: 12)).foregroundStyle(Theme.fg2)
                if let disk { Text("\(Fmt.bytes(disk.totalBytes)) disk").font(.system(size: 11)).foregroundStyle(Theme.fg3) }
            }
        }
        .frame(width: 220, height: 220)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Güvenle temizlenebilir").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.fg2)
            Text(Fmt.bytes(model.cleanableBytes))
                .font(.system(size: 42, weight: .bold, design: .rounded)).foregroundStyle(Theme.ok).monospacedDigit()
            Text("Yalnız kendini yeniden oluşturan öğeler sayıldı. Son 30 günde kullandığın projelerin artıkları, sarı ve kırmızılar senin onayını bekler; kullanımdakiler kilitli.")
                .foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 420, alignment: .leading)
            Button {
                model.selection = SelectionState(defaultsFrom: model.items)
                switch model.requestConfirm() {
                case .plan(let p): ui.sheet = .confirm(p)
                case .needsRescan: ui.sheet = .stale
                case .nothingSelected: ui.sheet = .nothingToClean
                }
            } label: {
                Label("Akıllı seçimi önizle", systemImage: "sparkles").padding(.horizontal, 4).padding(.vertical, 2)
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 6)
        }
    }

    private func card(_ info: CategoryInfo) -> some View {
        let its = model.items.filter { $0.category == info.category }
        let rc = Summaries.riskCounts(info.category == .apps ? its.filter { !$0.isLeftover } : its)
        let appsSum = Summaries.appsSummary(its)
        let green = its.filter { model.selection.effective($0).isDefaultSelected && model.selection.isSelectable($0) }
        let isApp = info.category == .apps
        let held = Summaries.heldBackGreens(its, selection: model.selection).count
        return Button { ui.section = .category(info.category) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    CategoryTile(tint: Theme.tint(info.category), symbol: info.symbol, size: 24)
                    Text(info.title).font(.system(size: 13, weight: .semibold))
                }
                Text(isApp ? "\(appsSum.appCount) uygulama" : Fmt.bytes(Summaries.totalBytes(green)))
                    .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                Text(isApp ? "artıklarıyla \(Fmt.bytes(appsSum.totalBytes))" : "güvenle temizlenebilir")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.fg2).padding(.top, -6)
                if held > 0 && !isApp {
                    Text("\(held) öğe yakın zamanda kullanılmış; seçmek sana kalmış")
                        .font(.system(size: 11)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, -4)
                }
                HStack(spacing: 4) {
                    if green.count > 0 && !isApp { Pill(text: "\(green.count)", color: Theme.ok) }
                    if rc.yellow > 0 { Pill(text: "\(rc.yellow)", color: Theme.warn) }
                    if rc.red > 0 { Pill(text: "\(rc.red)", color: Theme.bad) }
                    if rc.locked > 0 { Pill(text: "\(rc.locked)", color: Theme.mute) }
                }
                .frame(minHeight: 18, alignment: .leading)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct Donut<Center: View>: View {
    var segments: [(Color, Double)]
    @ViewBuilder var center: Center
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.07), lineWidth: 22)
            let ends = segments.reduce(into: [Double]()) { acc, s in acc.append((acc.last ?? 0) + s.1) }
            ForEach(Array(segments.enumerated()), id: \.offset) { i, s in
                let start = i == 0 ? 0 : ends[i - 1]
                Circle().trim(from: min(1, start), to: min(1, max(start, ends[i] - 0.002)))
                    .stroke(s.0, style: StrokeStyle(lineWidth: 22, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            .padding(0)
            center
        }
        .padding(11)
    }
}
