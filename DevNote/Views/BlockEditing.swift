import SwiftUI
import CoreData

// MARK: - Blok işlemleri (Enter, yapıştırma, birleştirme, dönüştürme)

/// Editörün istediği sayfa düzeyindeki işlemleri uygular. Belge ve Tuval ortak kullanır.
@MainActor
struct BlockOps {
    var page: Page
    var context: NSManagedObjectContext
    var focus: FocusState<UUID?>.Binding

    func perform(_ op: EditorOp, on block: Block) {
        guard !block.isDeleted, block.managedObjectContext != nil else { return }
        switch op {
        case .split(let tail):
            split(block, tail: tail)
        case .insertAbove:
            let kind: BlockKind = block.kind.continuesOnEnter ? block.kind : .text
            withAnimation(Theme.spring) {
                let new = page.addBlock(kind, after: page.block(before: block), in: context)
                new.indent = block.indent
                page.move(new, before: block)
            }
        case .paste(let items, let cursor):
            guard let last = withAnimation(Theme.spring, { page.insert(items, after: block, in: context) }) else { return }
            focusBlock(last, cursor: cursor ?? Int.max)
        case .mergeBackward:
            mergeBackward(block)
        case .convert(let kind):
            convert(block, to: kind)
        case .focusPrevious:
            if let previous = neighbor(of: block, step: -1) { focusBlock(previous, cursor: Int.max) }
        case .focusNext:
            if let next = neighbor(of: block, step: 1) { focusBlock(next, cursor: 0) }
        case .indent(let delta):
            block.indent = Int64(min(max(Int(block.indent) + delta, 0), 6))
            page.touch()
        }
    }

    func focusBlock(_ block: Block, cursor: Int) {
        FormatState.shared.pendingCursor[block.uuid] = cursor
        if focus.wrappedValue == block.uuid {
            // Zaten odakta: imleci hemen taşıması için odağı yenile
            focus.wrappedValue = nil
            DispatchQueue.main.async { focus.wrappedValue = block.uuid }
        } else {
            focus.wrappedValue = block.uuid
        }
    }

    private func split(_ block: Block, tail: String) {
        // Boş liste / yapılacak maddesinde Enter → önce girinti azalır, sonra normal metne döner (Notion)
        if block.text.isEmpty && tail.isEmpty && block.kind != .text {
            withAnimation(Theme.spring) {
                if block.kind.continuesOnEnter && block.indent > 0 {
                    block.indent -= 1
                } else {
                    block.kind = .text
                }
            }
            return
        }
        let kind: BlockKind = block.kind.continuesOnEnter ? block.kind : .text
        let new = withAnimation(Theme.spring) { page.addBlock(kind, text: tail, after: block, in: context) }
        focusBlock(new, cursor: 0)
    }

    private func mergeBackward(_ block: Block) {
        // Satır başında ⌫: önce tür (liste, başlık…) kalkar, sonra girinti, en son önceki satırla birleşir
        if block.kind != .text {
            withAnimation(Theme.spring) { block.kind = .text }
            return
        }
        if block.indent > 0 {
            block.indent -= 1
            return
        }
        guard let previous = page.block(before: block) else { return }
        switch previous.kind {
        case .divider:
            withAnimation(Theme.spring) { context.delete(previous) }
        case .image:
            if block.text.isEmpty { withAnimation(Theme.spring) { context.delete(block) } }
        default:
            let offset = RichText.parse(previous.text).characters.count
            if !block.text.isEmpty {
                if #available(iOS 26.0, macOS 26.0, *) {
                    EditorRequests.shared.append.send((previous.uuid, block.text))
                } else {
                    previous.text += (previous.text.isEmpty || block.text.isEmpty ? "" : "\u{200B}") + block.text
                }
            }
            withAnimation(Theme.spring) { context.delete(block) }
            focusBlock(previous, cursor: offset)
        }
        page.touch()
    }

    private func convert(_ block: Block, to kind: BlockKind) {
        switch kind {
        case .image:
            EditorRequests.shared.pickPhoto.send(block.uuid)
        case .divider:
            withAnimation(Theme.spring) {
                if block.text.isEmpty {
                    block.kind = .divider
                    let next = page.addBlock(.text, after: block, in: context)
                    focusBlock(next, cursor: 0)
                } else {
                    let divider = page.addBlock(.divider, after: page.block(before: block), in: context)
                    divider.indent = block.indent
                    page.move(divider, before: block)
                }
            }
        default:
            withAnimation(Theme.spring) { block.kind = kind }
            if focus.wrappedValue != block.uuid { focusBlock(block, cursor: Int.max) }
        }
        page.touch()
    }

    private func neighbor(of block: Block, step: Int) -> Block? {
        let blocks = page.sortedBlocks
        guard var index = blocks.firstIndex(of: block) else { return nil }
        while true {
            index += step
            guard blocks.indices.contains(index) else { return nil }
            if blocks[index].kind.hasText && blocks[index].kind != .image { return blocks[index] }
        }
    }

    /// Bloğun kopyası hemen altına
    func duplicate(_ block: Block) {
        let copy = withAnimation(Theme.spring) { page.addBlock(block.kind, text: block.text, after: block, in: context) }
        copy.indent = block.indent
        copy.imageData_ = block.imageData_
        copy.width = block.width
    }
}

// MARK: - "/" menüsü

/// Notion'daki gibi filtrelenen blok türleri listesi. Mac'te satırın altında, iPhone'da klavyenin üstünde.
struct SlashMenuView: View {
    /// nil: hangi blokta açıksa (iPhone paneli); değilse yalnızca bu blok için
    var blockID: UUID?
    @ObservedObject private var menu = SlashMenuState.shared

    var body: some View {
        if let session = menu.session, blockID == nil || session.blockID == blockID {
            let results = menu.results
            VStack(alignment: .leading, spacing: 0) {
                Text(session.query.isEmpty ? "Blok türü" : "“\(session.query)”")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                if results.isEmpty {
                    Text("Sonuç yok")
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(results.enumerated()), id: \.element) { index, kind in
                                    row(kind, highlighted: index == session.highlighted)
                                        .id(kind)
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.bottom, 4)
                        }
                        .frame(height: min(CGFloat(results.count) * Self.rowHeight + 4, Self.maxHeight))
                        .onChange(of: session.highlighted) { _, index in
                            if results.indices.contains(index) { proxy.scrollTo(results[index]) }
                        }
                    }
                }
            }
            .frame(width: blockID == nil ? nil : 280)
            .frame(maxWidth: blockID == nil ? .infinity : nil, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.secondary.opacity(0.2)))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
            .accessibilityIdentifier("slash-menu")
        }
    }

    #if os(iOS)
    private static let maxHeight: CGFloat = 220
    #else
    private static let maxHeight: CGFloat = 320
    #endif
    private static let rowHeight: CGFloat = 38

    private func row(_ kind: BlockKind, highlighted: Bool) -> some View {
        Button { menu.pick(kind) } label: {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .frame(width: 28, height: 28)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.25)))
                Text(kind.title)
                Spacer()
                if let shortcut = kind.shortcut {
                    Text(shortcut).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: Self.rowHeight)
            .background(highlighted ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
    }
}

// MARK: - Blok menüsü (⋮⋮ tutamacı)

/// Tutamaca dokununca: dönüştür, renk, vurgu, yorum, çoğalt, taşı, sil
struct BlockMenu: View {
    @ObservedObject var block: Block
    var onOp: (EditorOp) -> Void
    var onDuplicate: () -> Void
    var onComment: () -> Void
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if block.kind.hasText && block.kind != .image {
                    section("Dönüştür") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                            ForEach(BlockKind.textKinds) { kind in
                                Button { act { onOp(.convert(kind)) } } label: {
                                    Label(kind.title, systemImage: kind.symbol)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .background(kind == block.kind ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                                                    in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !block.text.isEmpty {
                        section("Yazı rengi") {
                            swatches(TextColor.allCases.map { ($0.rawValue, $0.color, $0.title) }, fill: false) { hex in
                                FormatCommands.shared.wholeBlock.send((block.uuid, .color(hex)))
                            }
                        }
                        section("Arka plan") {
                            swatches(HighlightColor.allCases.map { ($0.rawValue, $0.color, $0.title) }, fill: true) { hex in
                                FormatCommands.shared.wholeBlock.send((block.uuid, .highlight(hex)))
                            }
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    item("Yorum", "bubble.left") { onComment() }
                    item("Çoğalt", "plus.square.on.square") { onDuplicate() }
                    item("Yukarı taşı", "arrow.up") { withAnimation(Theme.spring) { block.page?.shift(block, by: -1) } }
                    item("Aşağı taşı", "arrow.down") { withAnimation(Theme.spring) { block.page?.shift(block, by: 1) } }
                    if block.kind.hasText && block.kind != .image {
                        item("Girinti artır", "increase.indent") { onOp(.indent(1)) }
                        item("Girinti azalt", "decrease.indent") { onOp(.indent(-1)) }
                    }
                    item("Sil", "trash", role: .destructive) { onDelete() }
                }
            }
            .padding(14)
        }
        .frame(minWidth: 280, idealWidth: 300, maxWidth: 340, maxHeight: 520)
    }

    private func act(_ action: () -> Void) {
        action()
        dismiss()
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func swatches(_ colors: [(String, Color, String)], fill: Bool, apply: @escaping (String?) -> Void) -> some View {
        HStack(spacing: 8) {
            Button { act { apply(nil) } } label: {
                Image(systemName: "nosign")
                    .frame(width: 26, height: 26)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Varsayılan")
            ForEach(colors, id: \.0) { hex, color, title in
                Button { act { apply(hex) } } label: {
                    Group {
                        if fill {
                            RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.45))
                        } else {
                            Text("A").font(.headline).foregroundStyle(color)
                        }
                    }
                    .frame(width: 26, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.25)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
            }
        }
    }

    private func item(_ title: String, _ symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role) { act(action) } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? .red : .primary)
    }
}

// MARK: - Biçim çubukları

/// Odaktaki bloğun türünü değiştiren menü ("Metin ⌄")
struct BlockKindPicker: View {
    @ObservedObject private var state = FormatState.shared
    var compact = false

    var body: some View {
        Menu {
            ForEach(BlockKind.textKinds) { kind in
                Button {
                    if let id = state.activeBlockID { SlashMenuState.shared.picked.send((id, kind)) }
                } label: {
                    if kind == state.kind {
                        Label(kind.title, systemImage: "checkmark")
                    } else {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
            }
        } label: {
            if compact {
                Image(systemName: state.kind.symbol)
            } else {
                HStack(spacing: 4) {
                    Text(state.kind.title).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
                .frame(minWidth: 110, alignment: .leading)
            }
        }
        .accessibilityLabel("Blok türü: \(state.kind.title)")
        .disabled(state.activeBlockID == nil)
    }
}

/// Word gibi üst biçim çubuğu (Mac ve iPad): tür, B I U S, kod, bağlantı, renk, vurgu, px boyut, temizle
struct FormatToolbar: View {
    @ObservedObject private var state = FormatState.shared
    @State private var sizeText = "17"
    @FocusState private var editingSize: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                BlockKindPicker()
                    .fixedSize()
                separator
                ForEach(InlineFormat.allCases) { format in
                    toggle(format)
                }
                separator
                ColorMenus()
                separator
                sizeControl
                separator
                Button { FormatCommands.shared.send(.clear) } label: {
                    Image(systemName: "eraser")
                        .frame(width: 28, height: 26)
                }
                .help("Biçimi temizle (⌘\\)")
                .accessibilityLabel("Biçimi temizle")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .disabled(state.activeBlockID == nil)
        .onAppear { sizeText = Self.format(state.pointSize) }
        .onChange(of: state.pointSize) { _, new in if !editingSize { sizeText = Self.format(new) } }
        .onChange(of: editingSize) { _, editing in
            FormatState.shared.editingToolbar = editing
            if !editing { sizeText = Self.format(state.pointSize) }
        }
    }

    private var separator: some View {
        Divider().frame(height: 18).padding(.horizontal, 2)
    }

    private func toggle(_ format: InlineFormat) -> some View {
        let on = isOn(format)
        return Button { FormatCommands.shared.send(format) } label: {
            Image(systemName: format.symbol)
                .frame(width: 28, height: 26)
                .background(on ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(on ? Color.accentColor : .primary)
        }
        .help(format.title)
        .accessibilityLabel(format.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func isOn(_ format: InlineFormat) -> Bool {
        switch format {
        case .bold: state.bold
        case .italic: state.italic
        case .underline: state.underline
        case .strikethrough: state.strikethrough
        case .code: state.code
        case .link: state.link
        }
    }

    private var sizeControl: some View {
        HStack(spacing: 2) {
            Button { FormatCommands.shared.send(.sizeStep(-1)) } label: {
                Image(systemName: "minus").frame(width: 22, height: 26)
            }
            .help("Küçült (⌘-)")
            .accessibilityLabel("Küçült")
            TextField("px", text: $sizeText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 48)
                .focused($editingSize)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onSubmit(applySize)
                .accessibilityLabel("Yazı boyutu (px)")
                .accessibilityIdentifier("font-size-field")
            Button { FormatCommands.shared.send(.sizeStep(1)) } label: {
                Image(systemName: "plus").frame(width: 22, height: 26)
            }
            .help("Büyüt (⌘+)")
            .accessibilityLabel("Büyüt")
            Menu {
                ForEach(TextSizes.presets, id: \.self) { size in
                    Button("\(Int(size)) px") { FormatCommands.shared.send(.size(size)) }
                }
                Divider()
                Button("Normal boyut") { FormatCommands.shared.send(.size(nil)) }
            } label: {
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Hazır boyutlar")
        }
    }

    private func applySize() {
        let value = Double(sizeText.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." })
        editingSize = false
        guard let value else { return }
        FormatCommands.shared.send(.size(min(max(value, TextSizes.range.lowerBound), TextSizes.range.upperBound)))
    }

    static func format(_ size: Double) -> String {
        size.rounded() == size ? String(Int(size)) : String(format: "%.1f", size)
    }
}

/// Yazı rengi ve arka plan (vurgu) menüleri
struct ColorMenus: View {
    var body: some View {
        Menu {
            ForEach(TextColor.allCases) { color in
                Button { FormatCommands.shared.send(.color(color.rawValue)) } label: {
                    Label { Text(color.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(color.color) }
                }
            }
            Divider()
            Button("Varsayılan", systemImage: "arrow.uturn.backward") { FormatCommands.shared.send(.color(nil)) }
        } label: {
            Image(systemName: "character").overlay(alignment: .bottom) {
                Capsule().fill(TextColor.red.color).frame(width: 14, height: 3).offset(y: 5)
            }
            .frame(width: 28, height: 26)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Yazı rengi")
        .accessibilityLabel("Yazı rengi")

        Menu {
            ForEach(HighlightColor.allCases) { color in
                Button { FormatCommands.shared.send(.highlight(color.rawValue)) } label: {
                    Label { Text(color.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(color.color) }
                }
            }
            Divider()
            Button("Arka planı kaldır", systemImage: "xmark") { FormatCommands.shared.send(.highlight(nil)) }
        } label: {
            Image(systemName: "highlighter").frame(width: 28, height: 26)
        } primaryAction: {
            FormatCommands.shared.send(.highlight(HighlightColor.yellow.rawValue))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Arka plan rengi (tıkla: sarı, basılı tut: renkler)")
        .accessibilityLabel("Vurgula")
    }
}
