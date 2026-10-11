import SwiftUI
import CoreData

/// Tek bir bloğun düzenlenebilir görünümü. Belge ve Tuval modları ortak kullanır.
struct BlockRow: View {
    @ObservedObject var block: Block
    var accent: Color
    var focus: FocusState<UUID?>.Binding
    /// Belge: Enter yeni blok, "/" menüsü. Tuval: Enter yeni satır.
    var documentMode = true
    var onOp: (EditorOp) -> Void = { _ in }
    var onDelete: () -> Void

    @Environment(\.participants) private var participants
    @Environment(\.canEditPage) private var canEdit
    @State private var pickingDate = false
    @State private var showingComments = false
    @State private var selection: TextSelection?

    private var isFocused: Bool { focus.wrappedValue == block.uuid }
    /// Düzenlenmezken Markdown biçimini göster (düzenlerken ham metin)
    private var showsRendered: Bool { !isFocused && InlineFormat.hasMarkup(block.text) }

    private var showsChips: Bool {
        (block.kind == .checklist && (block.assigneeID != nil || block.dueDate != nil || pickingDate))
            || !block.comments.isEmpty
    }

    var body: some View {
        if block.isDeleted || block.managedObjectContext == nil {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if block.kind == .image {
                    ImageBlockView(block: block, focus: focus, canEdit: canEdit)
                        .contextMenu { contextMenu }
                } else if block.kind == .divider {
                    divider
                } else {
                    row
                }
                if showsChips {
                    chips
                        .padding(.leading, (block.kind == .checklist ? 27 : 0) + CGFloat(block.indent) * 22)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(Theme.spring, value: block.assigneeID)
            .animation(Theme.spring, value: block.dueDate)
            .animation(Theme.spring, value: block.comments.count)
            .sheet(isPresented: $showingComments) { CommentsSheet(block: block) }
            .onReceive(FormatCommands.shared.subject) { action in
                // Zengin editör (iOS 26+) biçimi kendisi uygular; eski sistemlerde Markdown işaretleri eklenir
                guard !usesRichEditor, isFocused, canEdit, case .toggle(let format) = action else { return }
                apply(format)
            }
            .onReceive(SlashMenuState.shared.picked) { id, kind in
                // Eski sistemlerde tür değişikliğini editör yerine satır uygular
                guard !usesRichEditor, id == block.uuid else { return }
                onOp(.convert(kind))
            }
        }
    }

    private var usesRichEditor: Bool {
        if #available(iOS 26.0, macOS 26.0, *) { true } else { false }
    }

    /// Tamamlanmış görev, düzenlenmezken üstü çizili ve soluk görünür
    private var showsDoneOverlay: Bool { !isFocused && block.kind == .checklist && block.isDone }

    @ViewBuilder
    private var textInput: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            RichBlockEditor(block: block, focus: focus, font: font, placeholder: placeholder,
                            canEdit: canEdit, multiline: !documentMode || block.kind == .code,
                            documentMode: documentMode, onOp: onOp)
                .fontDesign(block.kind == .code ? .monospaced : .default)
                .onChange(of: block.text) { block.page?.touch() }
                .opacity(showsDoneOverlay ? 0 : 1)
                .overlay(alignment: .topLeading) {
                    if showsDoneOverlay { renderedText }
                }
        } else {
            legacyTextField
        }
    }

    private var renderedText: some View {
        Text(RichText.display(block.text))
            .font(font)
            .fontDesign(block.kind == .code ? .monospaced : .default)
            .strikethrough(block.kind == .checklist && block.isDone, color: .secondary)
            .foregroundStyle(block.kind == .checklist && block.isDone ? .secondary : .primary)
            .tint(accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if canEdit { focus.wrappedValue = block.uuid } }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            leading
            textInput
            if block.kind == .checklist, block.isDone, block.doneBy == .ai {
                AIBadge(note: block.doneNote)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, CGFloat(block.indent) * 22)
        .padding(.top, headingSpace)
        .padding(.vertical, 2)
        .padding(.horizontal, block.kind == .code || block.kind == .quote ? 10 : 0)
        .padding(.vertical, block.kind == .code ? 6 : 0)
        .background(background)
        .animation(Theme.spring, value: block.isDone)
        .animation(Theme.spring, value: block.kind_)
        .contextMenu { if showsRowMenu { contextMenu } }
    }

    /// iPhone'da yazarken basılı tutmak metin seçimi / yapıştırma içindir; blok menüsü tutamaçta
    private var showsRowMenu: Bool {
        #if os(iOS)
        !(isFocused && documentMode)
        #else
        true
        #endif
    }

    /// Başlıkların üstünde Notion gibi nefes payı
    private var headingSpace: CGFloat {
        switch block.kind {
        case .heading: 14
        case .heading2: 10
        case .heading3: 6
        default: 0
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.secondary.opacity(0.35))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.leading, CGFloat(block.indent) * 22)
            .contentShape(Rectangle())
            .contextMenu { contextMenu }
            .accessibilityLabel("Ayırıcı")
    }

    /// iOS 18–25 / macOS 15: düz metin alanı + Markdown işaretleri (düzenlenmezken biçimli görünür)
    private var legacyTextField: some View {
            TextField(placeholder, text: $block.text, selection: $selection, axis: .vertical)
                .textFieldStyle(.plain)
                .font(font)
                .fontDesign(block.kind == .code ? .monospaced : .default)
                .strikethrough(block.kind == .checklist && block.isDone, color: .secondary)
                .foregroundStyle(block.kind == .checklist && block.isDone ? .secondary : .primary)
                .focused(focus, equals: block.uuid)
                .disabled(!canEdit)
                .onSubmit { onOp(.split(tail: "")) }
                .onChange(of: block.text) { _, new in
                    applyMarkdownShortcut(new)
                    block.page?.touch()
                }
                .opacity(showsRendered ? 0 : 1)
                .overlay(alignment: .topLeading) {
                    // Biçimli görünüm; dokununca düzenlemeye geç (bağlantılar yine açılır)
                    if showsRendered { renderedText }
                }
    }

    // MARK: - Parçalar

    @ViewBuilder
    private var leading: some View {
        switch block.kind {
        case .checklist:
            Button {
                block.setDone(!block.isDone, by: .human)
                TaskActions.changed()
            } label: {
                Image(systemName: block.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(block.isDone ? (block.doneBy == .ai ? Theme.aiTint : accent) : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: block.isDone)
            }
            .buttonStyle(.plain)
            .disabled(!canEdit)
        case .bullet:
            // Notion gibi girintiye göre değişen madde imi
            Group {
                switch block.indent % 3 {
                case 0: Circle().fill(accent)
                case 1: Circle().strokeBorder(accent, lineWidth: 1.3)
                default: Rectangle().fill(accent)
                }
            }
            .frame(width: 6, height: 6)
            .offset(y: -3)
        case .numbered:
            Text("\(block.page?.listNumber(of: block) ?? 1).")
                .font(font)
                .monospacedDigit()
                .foregroundStyle(accent)
                .frame(minWidth: 18, alignment: .trailing)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var background: some View {
        switch block.kind {
        case .code:
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.6))
        case .quote:
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3)
                Spacer()
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Atama & son tarih

    private var chips: some View {
        HStack(spacing: 6) {
            if !block.comments.isEmpty {
                Button { showingComments = true } label: {
                    chip("\(block.comments.count)", symbol: "bubble.left.fill", tint: .blue)
                }
                .buttonStyle(.plain)
                .help("Yorumlar")
            }
            if let name = block.assigneeName {
                chip(name == "Ben" || block.assigneeID == Persistence.shared.me.id ? "Sana atandı" : "@\(name)",
                     symbol: "person.fill", tint: .green)
                    .help(block.assignedByName.map { "Atayan: \($0)" } ?? "")
            }
            if let due = block.dueDate {
                Button { pickingDate = true } label: {
                    chip(due.formatted(.relative(presentation: .named)),
                         symbol: "bell.fill", tint: due < .now && !block.isDone ? .red : .orange)
                }
                .buttonStyle(.plain)
            }
        }
        .popover(isPresented: $pickingDate) { duePicker }
    }

    private func chip(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private var duePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Hatırlatma", systemImage: "bell.fill").font(.headline)
            DatePicker("Tarih", selection: Binding(
                get: { block.dueDate ?? Calendar.current.date(byAdding: .hour, value: 1, to: .now)! },
                set: { block.dueDate = $0 }), in: Date.now...)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Button("Kaldır", role: .destructive) { block.dueDate = nil; pickingDate = false }
                Spacer()
                Button("Tamam") {
                    if block.dueDate == nil { block.dueDate = Calendar.current.date(byAdding: .hour, value: 1, to: .now) }
                    pickingDate = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 300)
        .onDisappear { TaskNotifier.shared.scheduleRefresh() }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(block.comments.isEmpty ? "Yorum Yaz…" : "Yorumlar (\(block.comments.count))…",
               systemImage: "bubble.left") { showingComments = true }
        Divider()
        if block.kind == .checklist && canEdit {
            if !participants.isEmpty {
                Menu("Ata", systemImage: "person.crop.circle.badge.plus") {
                    ForEach(participants) { person in
                        Button {
                            withAnimation(Theme.spring) { block.assign(to: person) }
                            TaskActions.changed()
                        } label: {
                            if person.id == block.assigneeID {
                                Label(person.name, systemImage: "checkmark")
                            } else {
                                Text(person.name)
                            }
                        }
                    }
                    if block.assigneeID != nil {
                        Divider()
                        Button("Atamayı kaldır", role: .destructive) { block.assign(to: nil) }
                    }
                }
            } else if Persistence.cloudEnabled {
                Button("Ata (önce defteri paylaş)", systemImage: "person.crop.circle.badge.plus") {}
                    .disabled(true)
            }
            Button(block.dueDate == nil ? "Hatırlatma Ekle…" : "Hatırlatmayı Değiştir…", systemImage: "bell") {
                pickingDate = true
            }
            #if os(iOS)
            if !block.isDone && LiveActivities.shared.isEnabled {
                if LiveActivities.shared.isTracking(block) {
                    Button("Dynamic Island'dan kaldır", systemImage: "pin.slash") { LiveActivities.shared.stop(block) }
                } else {
                    Button("Dynamic Island'da takip et", systemImage: "pin.circle") { LiveActivities.shared.start(block) }
                }
            }
            #endif
            Divider()
        }
        if canEdit {
            if block.kind != .image {
                Menu("Dönüştür", systemImage: "arrow.triangle.2.circlepath") {
                    ForEach(BlockKind.textKinds) { kind in
                        Button(kind.title, systemImage: kind.symbol) { onOp(.convert(kind)) }
                    }
                }
                Button("Girinti Artır", systemImage: "increase.indent") { block.indent = min(block.indent + 1, 6) }
                Button("Girinti Azalt", systemImage: "decrease.indent") { block.indent = max(block.indent - 1, 0) }
            }
            Button("Yukarı Taşı", systemImage: "arrow.up") {
                withAnimation(Theme.spring) { block.page?.shift(block, by: -1) }
            }
            Button("Aşağı Taşı", systemImage: "arrow.down") {
                withAnimation(Theme.spring) { block.page?.shift(block, by: 1) }
            }
        }
        if block.kind == .checklist && block.isDone && block.doneBy == .ai {
            Button("AI işaretini geri al", systemImage: "arrow.uturn.backward") {
                block.setDone(false, by: .human)
            }
        }
        if canEdit {
            Divider()
            Button("Sil", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private var font: Font {
        switch block.kind {
        case .heading: .title.weight(.bold)
        case .heading2: .title2.weight(.bold)
        case .heading3: .title3.weight(.semibold)
        case .quote: .body.italic()
        case .code: .callout
        default: .body
        }
    }

    private var placeholder: String {
        switch block.kind {
        case .heading: "Başlık 1"
        case .heading2: "Başlık 2"
        case .heading3: "Başlık 3"
        case .checklist: "Yapılacak"
        case .bullet, .numbered: "Liste"
        case .quote: "Alıntı"
        case .code: "Kod"
        case .image: "Açıklama"
        case .divider: ""
        case .text: documentMode ? "Yaz ya da komutlar için “/”" : "Yaz…"
        }
    }

    /// Seçili metne biçim uygula (seçim yoksa imlecin olduğu yere / sona)
    private func apply(_ format: InlineFormat) {
        let text = block.text
        var range = text.count..<text.count
        if let selection, case .selection(let r) = selection.indices,
           r.lowerBound >= text.startIndex, r.upperBound <= text.endIndex {
            range = text.distance(from: text.startIndex, to: r.lowerBound)..<text.distance(from: text.startIndex, to: r.upperBound)
        }
        let result = format.apply(to: text, selection: range)
        block.text = result.text
        let start = result.text.index(result.text.startIndex, offsetBy: result.selection.lowerBound)
        let end = result.text.index(result.text.startIndex, offsetBy: result.selection.upperBound)
        selection = TextSelection(range: start..<end)
    }

    /// Markdown kısayolları: "[] " → yapılacak, "# " → başlık, "- " → madde, "> " → alıntı, "``` " → kod
    private func applyMarkdownShortcut(_ text: String) {
        guard block.kind == .text else { return }
        let map: [(String, BlockKind)] = [("[] ", .checklist), ("[ ] ", .checklist), ("### ", .heading3),
                                         ("## ", .heading2), ("# ", .heading), ("- ", .bullet), ("* ", .bullet),
                                         ("1. ", .numbered), ("> ", .quote), ("``` ", .code)]
        for (prefix, kind) in map where text.hasPrefix(prefix) {
            withAnimation(Theme.spring) {
                block.kind = kind
                block.text = String(text.dropFirst(prefix.count))
            }
            return
        }
    }
}
