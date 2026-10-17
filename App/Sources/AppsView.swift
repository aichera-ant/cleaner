import CleanerAppCore
import CleanerKit
import SwiftUI

/// Uygulamalar sayfası: uygulamalar seçili sıralamada, artıkları kendi altında (açılır/kapanır, varsayılan kapalı).
struct AppsBody: View {
    let model: AppModel
    let ui: UIState
    @State private var request: SelectRequest?

    var body: some View {
        let layout = model.appsLayout(by: ui.sort)
        let everything = layout.groups.flatMap { [$0.app] + $0.leftovers }
        AppsHeader(model: model, ui: ui, layout: layout, everything: everything, request: $request)
        if layout.groups.isEmpty && layout.orphans.isEmpty {
            Banner(symbol: "checkmark.circle", tint: Theme.mute, text: Text("Bu bölümde temizlenecek bir şey kalmadı."))
        }
        if !layout.groups.isEmpty {
            Panel {
                AdaptiveStack {
                    ForEach(Array(layout.groups.enumerated()), id: \.element.id) { i, g in
                        if i > 0 { Divider().opacity(0.6) }
                        AppGroupView(group: g, model: model, ui: ui)
                    }
                }
            }
        }
        if !layout.orphans.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sahipsiz artıklar · \(layout.orphans.count) · \(Fmt.bytes(Summaries.totalBytes(layout.orphans)))")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.fg2)
                Text("Uygulaması bu taramada görünmeyen artıklar. Hangi uygulamaya ait olduklarını doğrulayamadığımız için buradan taşınamazlar; istersen Finder'da kendin bakabilirsin.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                Panel {
                    AdaptiveStack {
                        ForEach(Array(layout.orphans.enumerated()), id: \.element.id) { i, l in
                            if i > 0 { Divider().opacity(0.6) }
                            LeftoverRow(item: l, model: model, on: false, selectable: false, indent: 12,
                                        lockHelp: "Uygulaması bu taramada yok", toggle: {})
                        }
                    }
                }
            }
        }
    }
}

struct AppsHeader: View {
    let model: AppModel
    let ui: UIState
    let layout: AppsLayout
    let everything: [CleanItem]
    @Binding var request: SelectRequest?

    var body: some View {
        let sel = model.selection
        let nApps = layout.groups.reduce(0) { $0 + (sel.isSelected($1.app) ? 1 : 0) }
        let nLeft = layout.groups.reduce(0) { $0 + $1.leftovers.reduce(0) { $0 + (sel.isSelected($1) ? 1 : 0) } }
        HStack(spacing: 14) {
            Text("\(layout.groups.count) uygulama · \(nApps) seçili\(nLeft > 0 ? " · \(nLeft) artık seçili" : "")").foregroundStyle(Theme.fg2)
            Spacer()
            SortMenu(ui: ui)
            Button("Tümünü seç") { requestSelectAll(everything, model: model, request: $request) }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .help("Uygulamaları ve onların kesin artıklarını seçer; adı benzeyen artıklar seçilmez.")
            if nApps + nLeft > 0 {
                Button("Seçimi kaldır") { model.selection.deselectAll(in: everything) }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
        }
        .redSelectDialog($request, model: model)
    }
}

struct AppGroupView: View {
    let group: AppGroup
    let model: AppModel
    let ui: UIState

    var body: some View {
        let app = group.app
        let open = ui.expandedApps.contains(app.id)
        VStack(spacing: 0) {
            ItemRow(item: app, model: model, onToggle: { toggleApp() })
            if !group.leftovers.isEmpty {
                disclosure(open: open)
                if open {
                    ForEach(group.leftovers) { l in
                        Divider().opacity(0.4).padding(.leading, 56)
                        LeftoverRow(item: l, model: model, on: model.selection.isSelected(l),
                                    selectable: model.selection.isSelectable(l), indent: 56, lockHelp: l.lockReason,
                                    toggle: { model.selection.toggle(l) })
                    }
                }
            }
        }
    }

    private func disclosure(open: Bool) -> some View {
        let nSel = group.leftovers.reduce(0) { $0 + (model.selection.isSelected($1) ? 1 : 0) }
        let exact = group.exactCount
        let named = group.leftovers.count - exact
        return Button {
            if open { ui.expandedApps.remove(group.app.id) } else { ui.expandedApps.insert(group.app.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold)).frame(width: 12)
                Text("\(group.leftovers.count) artık · \(Fmt.bytes(group.leftoverBytes))").font(.system(size: 12, weight: .semibold))
                Text([exact > 0 ? "\(exact) kesin" : nil, named > 0 ? "\(named) adı benziyor" : nil].compactMap { $0 }.joined(separator: ", "))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.fg2)
                if nSel > 0 { Pill(text: "\(nSel) seçili", color: Theme.accent) }
                Spacer()
            }
            .foregroundStyle(Theme.accent)
            .padding(.leading, 56).padding(.trailing, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.leftovers.count) artık dosya, \(open ? "gizle" : "göster")")
    }

    /// Seçim kutusu: seçiliyse kaldırır (artıkları da); seçili değilse ve seçilebilir artığı varsa "Uygulama ve artıkları" sayfasını açar.
    private func toggleApp() {
        let app = group.app
        let sel = model.selection
        if sel.isSelected(app) || !sel.isSelectable(app) {
            model.selection.toggle(app)
        } else if sel.selectableLeftovers(of: app).isEmpty {
            model.selection.set(app, selected: true)
        } else {
            ui.sheet = .appLeftovers(app.id)
        }
    }
}

/// Etiket: artığın uygulamaya nasıl bağlandığı.
struct MatchPill: View {
    let match: LeftoverMatch?
    var body: some View {
        switch match {
        case .bundleID: Pill(text: "Kesin bu uygulamanın", color: Theme.ok)
        case .name: Pill(text: "Adı benziyor, başka uygulamaya ait olabilir", color: Theme.warn)
        case nil: EmptyView()
        }
    }
}

struct LeftoverRow: View {
    let item: CleanItem
    let model: AppModel
    let on: Bool
    let selectable: Bool
    var indent: CGFloat = 56
    var lockHelp: String?
    let toggle: () -> Void
    @State private var open = false

    /// "Application Support/ad" gibi: hangi Library klasöründe olduğu görünsün; ev klasöründeki gizli klasör olduğu gibi.
    static func title(_ item: CleanItem) -> String {
        let last = item.url.lastPathComponent
        let parent = item.url.deletingLastPathComponent()
        return parent.path == NSHomeDirectory() ? last : parent.lastPathComponent + "/" + last
    }

    var body: some View {
        let e = model.explanation(for: item)
        HStack(alignment: .top, spacing: 10) {
            CheckBox(on: on, enabled: selectable, lockHelp: lockHelp, action: toggle).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title(item)).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(e.what).font(.system(size: 11.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                MatchPill(match: item.leftoverMatch)
                if !selectable, let lock = lockHelp {
                    Label(lock, systemImage: "lock.fill").font(.system(size: 11)).foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if open {
                    Text("**Silersem ne olur?** \(e.consequence)").font(.system(size: 11.5)).foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Text(Fmt.tilde(item.path)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.fg3)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            HStack(spacing: 8) {
                Text(Fmt.bytes(item.allocatedBytes)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(selectable ? .primary : Theme.fg2)
                Button { open.toggle() } label: {
                    Image(systemName: open ? "info.circle.fill" : "info.circle").font(.system(size: 13)).foregroundStyle(Theme.fg3)
                }
                .buttonStyle(.plain).help("Silersem ne olur?").accessibilityLabel("Silersem ne olur?")
                RevealButton(path: item.path)
            }
        }
        .padding(.leading, indent).padding(.trailing, 12).padding(.vertical, 7)
        .background(on ? Theme.accent.opacity(0.08) : .clear)
        .accessibilityElement(children: .contain)
    }
}

/// "Uygulama ve artıkları" sayfası: yalnız seçimi düzenler, taşımaz.
struct AppLeftoversSheet: View {
    let model: AppModel
    let appID: String
    var onClose: () -> Void
    @State private var picked: Set<String>

    init(model: AppModel, appID: String, onClose: @escaping () -> Void) {
        self.model = model
        self.appID = appID
        self.onClose = onClose
        let app = model.items.first { $0.id == appID }
        _picked = State(initialValue: app.map { model.selection.defaultLeftoverIDs(of: $0) } ?? [])
    }

    var body: some View {
        if let app = model.items.first(where: { $0.id == appID }) {
            content(app)
        }
    }

    private func content(_ app: CleanItem) -> some View {
        let leftovers = model.selection.leftovers(of: app)
        let chosen = leftovers.filter { picked.contains($0.id) && model.selection.isSelectable($0) }
        let total = app.allocatedBytes &+ Summaries.totalBytes(chosen)
        let hasNamed = leftovers.contains { $0.leftoverMatch == .name }
        return SheetFrame {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ItemIcon(item: app)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(app.name) ve artıkları").font(.system(size: 17, weight: .bold, design: .rounded))
                        Text("Uygulama \(Fmt.bytes(app.allocatedBytes)) · \(leftovers.count) artık \(Fmt.bytes(Summaries.totalBytes(leftovers)))")
                            .foregroundStyle(Theme.fg2)
                    }
                }
                Text("Uygulamayı kaldırınca ayarları, önbelleği ve verileri geride kalır. Hangilerinin birlikte taşınacağını seç. Bu sayfa yalnız seçimi düzenler; taşıma, \"Önizle\" ile onayladığında olur.")
                    .font(.system(size: 12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                if hasNamed {
                    Text("**Sarı olanlar yalnız adı benzediği için bulundu** ve başka bir uygulamaya ait olabilir; emin değilsen işaretleme.")
                        .font(.system(size: 12)).foregroundStyle(Theme.fg2)
                        .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.warn.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                if Fmt.needsAuthorization(app) {
                    Label("**macOS parolayı bir kez isteyecek:** bu uygulama macOS tarafından korunuyor.", systemImage: "touchid")
                        .font(.system(size: 12)).foregroundStyle(Theme.fg2)
                        .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                Scroller {
                    VStack(spacing: 0) {
                        ForEach(Array(leftovers.enumerated()), id: \.element.id) { i, l in
                            if i > 0 { Divider().opacity(0.5) }
                            let selectable = model.selection.isSelectable(l)
                            LeftoverRow(item: l, model: model, on: picked.contains(l.id) && selectable, selectable: selectable,
                                        indent: 10, lockHelp: l.lockReason, toggle: {
                                if picked.contains(l.id) { picked.remove(l.id) } else { picked.insert(l.id) }
                            })
                        }
                    }
                }
                .frame(maxHeight: 300).clipped()
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                Text("Toplam \(Fmt.bytes(total)) · uygulama + \(chosen.count) artık").foregroundStyle(Theme.fg2).monospacedDigit()
                HStack(spacing: 8) {
                    Spacer()
                    Button("Vazgeç", action: onClose).buttonStyle(SoftButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("Yalnız uygulamayı seç") { apply(app, ids: []) }.buttonStyle(SoftButtonStyle())
                    Button("Uygulamayı ve seçili artıkları seç") { apply(app, ids: Set(chosen.map(\.id))) }
                        .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(chosen.isEmpty)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Uygulama ve artıkları")
    }

    private func apply(_ app: CleanItem, ids: Set<String>) {
        model.selection.selectApp(app, leftoverIDs: ids)
        onClose()
    }
}
