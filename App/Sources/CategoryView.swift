import AppKit
import CleanerAppCore
import CleanerKit
import SwiftUI

struct CategoryView: View {
    let model: AppModel
    let ui: UIState
    let category: CleanerKit.Category

    private var info: CategoryInfo { CategoryInfo.info(for: category) }
    private var items: [CleanItem] { Summaries.items(in: category, model.items) }

    var body: some View {
        Scroller {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    CategoryTile(tint: Theme.tint(category), symbol: info.symbol, size: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info.title).font(.system(size: 22, weight: .bold, design: .rounded))
                        Text(info.blurb).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 560, alignment: .leading)
                    }
                }
                if category == .duplicates {
                    DuplicatesBody(model: model)
                } else {
                    listBody
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 22)
        }
    }

    @ViewBuilder private var listBody: some View {
        let its = items
        let nsel = its.filter { model.selection.isSelected($0) }.count
        HStack {
            Text("\(its.count) öğe · \(nsel) seçili").foregroundStyle(Theme.fg2)
            Spacer()
            if its.contains(where: { $0.risk == .green && model.selection.isSelectable($0) }) {
                Button(model.selection.allGreensSelected(in: its) ? "Yeşillerin seçimini kaldır" : "Tüm yeşilleri seç") {
                    model.selection.toggleGreens(in: its)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
        }
        if its.isEmpty {
            Banner(symbol: "checkmark.circle", tint: Theme.mute, text: Text("Bu bölümde temizlenecek bir şey kalmadı."))
        } else {
            Panel {
                VStack(spacing: 0) {
                    ForEach(Array(its.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider().opacity(0.6) }
                        ItemRow(item: item, selection: model.selection, onToggle: { model.selection.toggle(item) })
                    }
                }
            }
        }
    }
}

struct ItemRow: View {
    let item: CleanItem
    let selection: SelectionState
    var onToggle: () -> Void

    private var selectable: Bool { selection.isSelectable(item) }
    private var on: Bool { selection.isSelected(item) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CheckBox(on: on, enabled: selectable, lockHelp: item.lockReason, action: onToggle).padding(.top, 5)
            ItemIcon(item: item)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(Fmt.tilde(item.path)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.fg2)
                    .lineLimit(2).truncationMode(.middle)
                notes
                HStack(spacing: 8) {
                    Pill(text: Fmt.riskLabel(item), color: Theme.riskColor(item))
                    if Fmt.needsAuthorization(item) {
                        Pill(text: "macOS parola ya da Touch ID isteyecek", color: Theme.warn)
                    }
                    DateText(signal: item.dateSignal)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 6)
            HStack(spacing: 8) {
                Text(Fmt.bytes(item.allocatedBytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(item.isLocked ? Theme.fg2 : .primary)
                RevealButton(path: item.path)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(on ? Theme.accent.opacity(0.10) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var notes: some View {
        if let lock = item.lockReason {
            Label(lock, systemImage: "lock.fill").font(.system(size: 11.5)).foregroundStyle(Theme.fg2)
                .labelStyle(.titleAndIcon).fixedSize(horizontal: false, vertical: true)
        }
        if let note = item.note, !note.isEmpty {
            Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
        }
        if case .command(let cmd) = item.method {
            Text("Komutla temizlenir, Çöp Kutusu'na gitmez: \(cmd)").font(.system(size: 11.5)).foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let rel = item.relatedPaths, !rel.isEmpty {
            Text("\(rel.count) artık dosya birlikte taşınır").font(.system(size: 11.5)).foregroundStyle(Theme.fg2)
        }
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

struct ItemIcon: View {
    let item: CleanItem
    @Environment(\.snapshotMode) private var snapshot
    var body: some View {
        // PNG çiziminde gerçek uygulama simgesi kullanılmaz (ImageRenderer NSImage ile bozuluyor); harf kutusu çizilir.
        if item.category == .apps, !snapshot, FileManager.default.fileExists(atPath: item.path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 32, height: 32)
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
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
        if item.category == .duplicates { return "doc.fill" }
        if exists { return isDir.boolValue ? "folder.fill" : "doc.fill" }
        return CategoryInfo.info(for: item.category).symbol
    }
}

struct DuplicatesBody: View {
    let model: AppModel

    var body: some View {
        let groups = Summaries.duplicateGroups(model.items)
        let selected = model.selectedItems.filter { $0.category == .duplicates }
        Banner(symbol: "doc.on.doc", tint: Theme.mute,
               text: Text("Yalnız içeriği birebir aynı dosyalar listelenir (boyut, ilk 1 MB, tam özet sırasıyla). Yeniden oluşan klasörlerdeki kopyalar kendi bölümlerinde temizlenir. Yalnız iCloud'da duran dosyalar okunmaz, çünkü okumak onları Mac'e indirir."))
        HStack {
            Text("\(groups.count) grup · seçili kopyalar: ")
                .foregroundStyle(Theme.fg2)
            + Text(Fmt.bytes(Summaries.totalBytes(selected))).fontWeight(.semibold)
            Spacer()
        }
        if groups.isEmpty {
            Banner(symbol: "checkmark.circle", tint: Theme.mute, text: Text("Mükerrer dosya bulunamadı."))
        }
        ForEach(groups) { g in group(g) }
    }

    private func group(_ g: DuplicateGroup) -> some View {
        let first = g.members[0]
        let save = g.perCopyBytes * UInt64(max(0, g.members.count - 1))
        return Panel {
            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    ItemIcon(item: first)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(first.name).font(.system(size: 13, weight: .bold))
                        Text("\(g.members.count) kopya · her biri \(Fmt.bytes(g.perCopyBytes)) · içerik birebir aynı")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.fg2)
                    }
                    Spacer()
                    if g.untouchable {
                        Pill(text: "Dokunulmaz", color: Theme.mute)
                    } else {
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
        return HStack(alignment: .top, spacing: 10) {
            CheckBox(on: on, enabled: sel.isSelectable(m), lockHelp: m.lockReason ?? (kept ? "Tutulacak kopya" : nil)) {
                model.selection.toggle(m)
            }
            .opacity(kept ? 0.0 : 1).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(Fmt.tilde(m.path)).font(.system(size: 11.5, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                if let lock = m.lockReason { Text(lock).font(.system(size: 11.5)).foregroundStyle(Theme.fg2) }
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
                Pill(text: Fmt.riskLabel(m), color: Theme.riskColor(m))
            }
            RevealButton(path: m.path)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(on ? Theme.accent.opacity(0.10) : .clear)
    }
}
