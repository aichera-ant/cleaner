import AppKit
import CleanerAppCore
import CleanerKit
import SwiftUI

struct CategoryView: View {
    let model: AppModel
    let ui: UIState
    let category: ItemCategory

    private var info: CategoryInfo { CategoryInfo.info(for: category) }

    var body: some View {
        Scroller {
            AdaptiveStack(spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    CategoryTile(tint: Theme.tint(category), symbol: info.symbol, size: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info.title).font(.system(size: 22, weight: .bold, design: .rounded))
                        Text(ItemExplainer.categoryIntro(category)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 560, alignment: .leading)
                    }
                }
                if category == .duplicates {
                    DuplicatesBody(model: model)
                } else if category == .apps {
                    AppsBody(model: model, ui: ui)
                } else {
                    CategoryList(model: model, ui: ui, category: category)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 22)
        }
    }
}

/// Canlıda tembel (yalnız görünen satırlar kurulur), PNG çiziminde (ImageRenderer) düz yığın.
struct AdaptiveStack<Content: View>: View {
    @Environment(\.snapshotMode) private var snapshot
    var spacing: CGFloat = 0
    @ViewBuilder var content: Content
    var body: some View {
        if snapshot {
            VStack(alignment: .leading, spacing: spacing) { content }
        } else {
            LazyVStack(alignment: .leading, spacing: spacing) { content }
        }
    }
}

/// "Kırmızılar da seçilecek" onayı. `request` doluyken iletişim kutusu açılır.
struct SelectRequest: Identifiable {
    let id = UUID()
    let items: [CleanItem]
    let red: Int
}

extension View {
    func redSelectDialog(_ request: Binding<SelectRequest?>, model: AppModel) -> some View {
        confirmationDialog(
            "\(request.wrappedValue?.red ?? 0) kırmızı öğe de seçilecek (geri gelmeyebilir). Devam?",
            isPresented: Binding(get: { request.wrappedValue != nil }, set: { if !$0 { request.wrappedValue = nil } }),
            titleVisibility: .visible, presenting: request.wrappedValue
        ) { r in
            Button("Yalnız yeşil ve sarı") { model.selection.selectAll(in: r.items, includeRed: false) }
            Button("Kırmızılar dahil hepsi", role: .destructive) { model.selection.selectAll(in: r.items, includeRed: true) }
            Button("Vazgeç", role: .cancel) {}
        }
    }
}

/// Toplu seçim isteği: kırmızı yoksa doğrudan seçer, varsa onay ister.
@MainActor
func requestSelectAll(_ items: [CleanItem], model: AppModel, request: Binding<SelectRequest?>) {
    let p = model.selection.selectAllPreview(in: items)
    if p.added == 0 { return }
    if p.red == 0 { model.selection.selectAll(in: items, includeRed: true) } else {
        request.wrappedValue = SelectRequest(items: items, red: p.red)
    }
}

/// Başlık satırı: yalnız seçim değişince yeniden çizilir (satırlar etkilenmez).
struct CategoryListHeader: View {
    let model: AppModel
    let ui: UIState
    let items: [CleanItem]
    @State private var request: SelectRequest?

    var body: some View {
        let nsel = items.reduce(0) { $0 + (model.selection.isSelected($1) ? 1 : 0) }
        HStack(spacing: 14) {
            Text("\(items.count) öğe · \(nsel) seçili").foregroundStyle(Theme.fg2)
            Spacer()
            SortMenu(ui: ui)
            Button("Tümünü seç") { requestSelectAll(items, model: model, request: $request) }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
            if nsel > 0 {
                Button("Seçimi kaldır") { model.selection.deselectAll(in: items) }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
        }
        .redSelectDialog($request, model: model)
    }
}

struct SortMenu: View {
    let ui: UIState
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        if snapshot {
            Label("Sırala: \(ui.sort.title)", systemImage: "arrow.up.arrow.down").foregroundStyle(Theme.accent)
        } else {
            Menu {
                Picker("Sırala", selection: Binding(get: { ui.sort }, set: { ui.sort = $0 })) {
                    ForEach(ItemSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sırala: \(ui.sort.title)", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton).fixedSize().foregroundStyle(Theme.accent)
        }
    }
}

struct CategoryList: View {
    let model: AppModel
    let ui: UIState
    let category: ItemCategory

    var body: some View {
        let its = model.sortedItems(in: category, by: ui.sort)
        CategoryListHeader(model: model, ui: ui, items: its)
        if its.isEmpty {
            Banner(symbol: "checkmark.circle", tint: Theme.mute, text: Text("Bu bölümde temizlenecek bir şey kalmadı."))
        } else {
            Panel {
                AdaptiveStack {
                    ForEach(Array(its.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider().opacity(0.6) }
                        ItemRow(item: item, model: model)
                    }
                }
            }
        }
    }
}

struct ItemRow: View {
    let item: CleanItem
    let model: AppModel
    /// nil: `model.selection.toggle(item)`. Uygulamalar sayfası kendi akışını verir (artık sayfası).
    var onToggle: (() -> Void)?
    @State private var open = false

    var body: some View {
        let e = model.explanation(for: item)
        let selectable = model.selection.isSelectable(item)
        let on = model.selection.isSelected(item)
        HStack(alignment: .top, spacing: 10) {
            CheckBox(on: on, enabled: selectable, lockHelp: item.lockReason, action: { if let onToggle { onToggle() } else { model.selection.toggle(item) } }).padding(.top, 5)
            ItemIcon(item: item)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(e.what).font(.system(size: 12)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                if let lock = item.lockReason {
                    Label(lock, systemImage: "lock.fill").font(.system(size: 11.5)).foregroundStyle(Theme.fg2)
                        .labelStyle(.titleAndIcon).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(e.heads.filter { !$0.hasPrefix("Şu an kullanımda") }, id: \.self) { h in
                    Text(h).font(.system(size: 11.5)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    RecoveryBadge(recovery: e.recovery)
                    if item.isLocked || item.risk == .red || item.risk == .info {
                        Pill(text: Fmt.riskLabel(item), color: Theme.riskColor(item))
                    }
                    if Fmt.needsAuthorization(item) {
                        Pill(text: "macOS parola ya da Touch ID isteyecek", color: Theme.warn)
                    }
                    DateText(signal: item.dateSignal)
                }
                .padding(.top, 2)
                if open { details(e) }
                Text(Fmt.tilde(item.path)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.fg3)
                    .lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            HStack(spacing: 8) {
                Text(Fmt.bytes(item.allocatedBytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(item.isLocked ? Theme.fg2 : .primary)
                Button { open.toggle() } label: {
                    Image(systemName: open ? "info.circle.fill" : "info.circle").font(.system(size: 14)).foregroundStyle(Theme.fg3)
                }
                .buttonStyle(.plain).help("Silersem ne olur?").accessibilityLabel("Silersem ne olur?")
                RevealButton(path: item.path)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(on ? Theme.accent.opacity(0.10) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { open.toggle() }
        .accessibilityElement(children: .contain)
    }

    private func details(_ e: ItemExplanation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("**Silersem ne olur?** \(e.consequence)").font(.system(size: 11.5)).foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
            if case .command(let cmd) = item.method {
                Text("Komutla temizlenir, Çöp Kutusu'na gitmez: \(cmd)").font(.system(size: 11)).foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = item.note, !note.isEmpty {
                Text("Teknik not: \(note)").font(.system(size: 11)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct DateText: View {
    let signal: DateSignal
    var body: some View {
        let d = Fmt.dateText(signal)
        Text("\(d.label) \(d.value)").font(.system(size: 11.5)).foregroundStyle(Theme.fg2).monospacedDigit()
    }
}

struct RevealButton: View {
    let path: String
    var body: some View {
        Button { Actions.reveal(path) } label: {
            Image(systemName: "magnifyingglass.circle").font(.system(size: 14)).foregroundStyle(Theme.fg3)
        }
        .buttonStyle(.plain)
        .help("Finder'da göster")
        .accessibilityLabel("Finder'da göster")
    }
}

/// Uygulama simgeleri yolu başına bir kez okunur (LaunchServices çağrısı pahalı).
@MainActor
enum AppIconCache {
    private static let cache = NSCache<NSString, NSImage>()
    static func icon(for path: String) -> NSImage? {
        if let i = cache.object(forKey: path as NSString) { return i }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(i, forKey: path as NSString)
        return i
    }
}

struct ItemIcon: View {
    let item: CleanItem
    @Environment(\.snapshotMode) private var snapshot
    var body: some View {
        // PNG çiziminde gerçek uygulama simgesi kullanılmaz (ImageRenderer NSImage ile bozuluyor); harf kutusu çizilir.
        if item.category == .apps, !snapshot, let icon = AppIconCache.icon(for: item.path) {
            Image(nsImage: icon).resizable().frame(width: 32, height: 32)
        } else if item.category == .apps {
            let letter = String(item.name.first ?? "?").uppercased()
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.tint(.apps).gradient).frame(width: 32, height: 32)
                .overlay(Text(letter).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white))
        } else {
            let tint = Theme.tint(item.category)
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.14)).frame(width: 32, height: 32)
                .overlay(Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(tint))
        }
    }

    private var symbol: String {
        // Mükerrerlerde dosya sistemine bakılmaz (satır başına stat yok).
        if item.category == .duplicates { return "doc.fill" }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
        if exists { return isDir.boolValue ? "folder.fill" : "doc.fill" }
        return CategoryInfo.info(for: item.category).symbol
    }
}

struct DuplicatesBody: View {
    let model: AppModel
    @State private var request: SelectRequest?

    var body: some View {
        // Gruplar tarama başına bir kez hesaplanır; bu gövde seçimi okumaz (onay kutusu tüm sayfayı çizdirmez).
        let groups = model.duplicateGroups
        Banner(symbol: "doc.on.doc", tint: Theme.mute,
               text: Text("Yalnız içeriği birebir aynı dosyalar listelenir (boyut, ilk 1 MB, tam özet sırasıyla). Yeniden oluşan klasörlerdeki kopyalar kendi bölümlerinde temizlenir. Yalnız iCloud'da duran dosyalar okunmaz, çünkü okumak onları Mac'e indirir."))
        DuplicatesHeader(model: model, groupCount: groups.count, request: $request)
        if groups.isEmpty {
            Banner(symbol: "checkmark.circle", tint: Theme.mute, text: Text("Mükerrer dosya bulunamadı."))
        }
        ForEach(groups) { g in DuplicateGroupView(model: model, group: g, request: $request) }
    }
}

struct DuplicatesHeader: View {
    let model: AppModel
    let groupCount: Int
    @Binding var request: SelectRequest?

    var body: some View {
        let all = model.duplicateGroups.flatMap(\.members)
        let selected = model.selectedItems.filter { $0.category == .duplicates }
        HStack(spacing: 14) {
            Text("\(groupCount) grup (toplam boyuta göre) · seçili kopyalar: ")
                .foregroundStyle(Theme.fg2)
            + Text(Fmt.bytes(Summaries.totalBytes(selected))).fontWeight(.semibold)
            Spacer()
            Button("Bütün fazla kopyaları seç (her gruptan bir kopya kalır)") {
                requestSelectAll(all, model: model, request: $request)
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            if !selected.isEmpty {
                Button("Seçimi kaldır") { model.selection.deselectAll(in: all) }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
        }
        .redSelectDialog($request, model: model)
    }
}

struct DuplicateGroupView: View {
    let model: AppModel
    let group: DuplicateGroup
    @Binding var request: SelectRequest?

    var body: some View {
        let g = group
        let first = g.members[0]
        let save = g.perCopyBytes * UInt64(max(0, g.members.count - 1))
        Panel {
            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    ItemIcon(item: first)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(first.name).font(.system(size: 13, weight: .bold))
                        Text("\(g.members.count) kopya · her biri \(Fmt.bytes(g.perCopyBytes)) · içerik birebir aynı")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.fg2)
                        Text("Bir kopya kalır, silinenler kendiliğinden geri gelmez (Çöp Kutusu'ndan alınabilir).")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.fg2)
                    }
                    Spacer()
                    if g.untouchable {
                        Pill(text: "Dokunulmaz", color: Theme.mute)
                    } else {
                        Button("Bu gruptaki fazla kopyaları seç") {
                            requestSelectAll(g.members, model: model, request: $request)
                        }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                        Text(save > 0 ? "−" + Fmt.bytes(save) : "—").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.ok).monospacedDigit()
                    }
                }
                .padding(12)
                ForEach(g.members) { m in
                    Divider().opacity(0.6)
                    member(m)
                }
            }
        }
    }

    private func member(_ m: CleanItem) -> some View {
        let sel = model.selection
        let kept = sel.isKeeper(m)
        let on = sel.isSelected(m)
        // "Bunu tut" seçimi uygulanmış hali: özgün tutulacak kopya başkası tutulunca taşınabilir görünür.
        let e = sel.effective(m)
        return HStack(alignment: .top, spacing: 10) {
            CheckBox(on: on, enabled: sel.isSelectable(m), lockHelp: e.lockReason ?? (kept ? "Tutulacak kopya" : nil)) {
                model.selection.toggle(m)
            }
            .opacity(kept ? 0.0 : 1).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(Fmt.tilde(m.path)).font(.system(size: 11.5, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                if let lock = e.lockReason { Text(lock).font(.system(size: 11.5)).foregroundStyle(Theme.fg2) }
                if let n = m.note, !kept, !n.isEmpty { Text(n).font(.system(size: 11.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true) }
                DateText(signal: m.dateSignal)
            }
            Spacer(minLength: 6)
            if kept {
                Pill(text: "Tutulacak", color: Theme.accent)
            } else if m.isLocked {
                Pill(text: "Kullanımda", color: Theme.mute)
            } else {
                Button("Bunu tut") { model.selection.keep(m) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.fg2)
                    .padding(.horizontal, 9).padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                if e.isLocked {
                    Pill(text: "Kullanımda", color: Theme.mute)
                } else {
                    Pill(text: Fmt.riskLabel(e), color: Theme.riskColor(e))
                }
            }
            RevealButton(path: m.path)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(on ? Theme.accent.opacity(0.10) : .clear)
    }
}
