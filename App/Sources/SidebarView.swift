import CleanerAppCore
import CleanerKit
import SwiftUI

struct SidebarView: View {
    let model: AppModel
    let ui: UIState
    let perms: PermissionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Spacer().frame(width: 62) // trafik ışıkları için yer
                Text("Cleaner").font(.system(size: 13, weight: .bold, design: .rounded))
                Spacer()
            }
            .frame(height: 52)

            Scroller {
                VStack(alignment: .leading, spacing: 1) {
                    row(.overview, title: "Özet", tint: Theme.overviewTint, symbol: "gauge.with.dots.needle.33percent", size: nil)
                    ForEach(CategoryInfo.sections, id: \.name) { sec in
                        Text(sec.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.fg3)
                            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
                        ForEach(sec.categories) { info in
                            row(.category(info.category), title: info.title, tint: Theme.tint(info.category), symbol: info.symbol,
                                size: sizeText(info.category))
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
            }
            PermissionsRow(perms: perms) { ui.sheet = .permissions }
                .padding(.horizontal, 10).padding(.bottom, 6)
            DiskFooter(disk: model.disk)
        }
        .background(SidebarBackground())
    }

    private func sizeText(_ c: ItemCategory) -> String? {
        guard model.snapshot != nil, model.phase != .scanning, !model.resultsOutdated else { return nil }
        let its = model.items.filter { $0.category == c }
        if c == .apps {
            let n = its.filter { !$0.isLeftover }.count
            return n == 0 ? nil : "\(n)"
        }
        let b = Summaries.totalBytes(its)
        return b == 0 ? nil : Fmt.bytes(b)
    }

    private func row(_ s: Section, title: String, tint: Color, symbol: String, size: String?) -> some View {
        let selected = ui.section == s
        return Button {
            if model.phase == .result { model.dismissResult() }
            ui.section = s
        } label: {
            HStack(spacing: 9) {
                CategoryTile(tint: tint, symbol: symbol, size: 22)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                if let size {
                    Text(size).font(.system(size: 11.5)).foregroundStyle(Theme.fg2).monospacedDigit()
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? Theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct DiskFooter: View {
    var disk: DiskInfo?
    var body: some View {
        if let disk {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack {
                    Text("Boş alan")
                    Spacer()
                    Text(Fmt.bytes(disk.availableBytes)).fontWeight(.semibold)
                }
                .font(.system(size: 11.5)).foregroundStyle(Theme.fg2).monospacedDigit()
                    .padding(.top, 6)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule().fill(LinearGradient(colors: [Theme.bad, Theme.warn], startPoint: .leading, endPoint: .trailing))
                            .frame(width: g.size.width * CGFloat(Double(disk.usedBytes) / Double(max(1, disk.totalBytes))))
                    }
                }
                .frame(height: 5)
                Text("\(Fmt.bytes(disk.usedBytes)) dolu · \(Fmt.bytes(disk.totalBytes))")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.fg3).monospacedDigit()
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        }
    }
}
