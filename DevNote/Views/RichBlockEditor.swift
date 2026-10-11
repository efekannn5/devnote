import SwiftUI

/// Editörün sayfa düzeyinde yapılmasını istediği işlemler (bloğu bölme, birleştirme, yeni bloklar…)
enum EditorOp {
    /// Enter: imleçten sonrası (Markdown) yeni bloğa
    case split(tail: String)
    /// Satır başında Enter: üste boş satır
    case insertAbove
    /// Çok satırlı yapıştırma: bu blokların arkasına eklenmesi; imleç son bloğun bu konumuna
    case paste(items: [MarkdownBlocks.Item], cursor: Int?)
    /// Satır başında ⌫: önceki blokla birleş / türü metne çevir
    case mergeBackward
    /// "/" menüsünden ya da Markdown kısayolundan tür değişikliği
    case convert(BlockKind)
    case focusPrevious, focusNext
    case indent(Int)
}

/// Bloğun zengin metin editörü (iOS 26 / macOS 26): biçim doğrudan uygulanır, Markdown işaretleri görünmez.
/// Hiçbir şey seçili değilken biçime basınca yazmaya o biçimle devam edilir.
@available(iOS 26.0, macOS 26.0, *)
struct RichBlockEditor: View {
    @ObservedObject var block: Block
    var focus: FocusState<UUID?>.Binding
    var font: Font
    var placeholder: String
    var canEdit: Bool
    /// Tuval kutusu ve kod bloğu: Enter yeni satır. Belgede Enter yeni blok.
    var multiline: Bool
    /// "/" menüsü ve blok işlemleri yalnızca belge modunda
    var documentMode: Bool
    var onOp: (EditorOp) -> Void

    @Environment(\.fontResolutionContext) private var fontContext
    @Environment(\.self) private var environment
    @State private var text = AttributedString()
    @State private var selection = AttributedTextSelection()
    /// Son işlenen metin: yeni metinle karşılaştırıp neyin yazıldığını / yapıştırıldığını buluruz
    @State private var previous = AttributedString()
    /// En son yazdığımız / okuduğumuz Markdown; farklıysa değişiklik dışarıdan gelmiştir (iCloud, MCP)
    @State private var syncedMarkdown: String?
    /// Biçim çubuğundan (odak dışındayken) gelen değişiklik de kaydedilsin
    @State private var formatting = false
    /// Metnin kurulduğu yazı tipi: tür değişince (başlık ↔ metin) biçimler buna göre yeniden ölçeklenir
    @State private var appliedFont: Font?
    @State private var askingLink = false
    @State private var linkText = "https://"

    private var isFocused: Bool { focus.wrappedValue == block.uuid }

    private var base: BaseStyle {
        let resolved = font.resolve(in: fontContext)
        return BaseStyle(font: font, pointSize: resolved.pointSize, bold: resolved.isBold, italic: resolved.isItalic)
    }

    private var plain: String { String(text.characters) }

    var body: some View {
        TextEditor(text: $text, selection: $selection)
            .font(font)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .textEditorStyle(.plain)
            // Metin alanının iç boşluklarını sıfırla: düz metinle aynı hizada dursun
            #if os(iOS)
            .padding(.horizontal, -5)
            .padding(.vertical, -8)
            #else
            .padding(.horizontal, -5)
            #endif
            .focused(focus, equals: block.uuid)
            .disabled(!canEdit)
            // Boş metin alanının taban çizgisi yok: onay kutusu / madde imi ilk satırla hizalı kalsın
            .alignmentGuide(.firstTextBaseline) { d in
                text.characters.isEmpty ? d[.top] + base.pointSize * 0.96 : d[.firstTextBaseline]
            }
            .overlay(alignment: .topLeading) {
                // Notion gibi: boş metin satırında ipucu yalnızca yazarken görünür
                if text.characters.isEmpty && (isFocused || block.kind != .text || !documentMode) {
                    Text(placeholder)
                        .font(font)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
            .onKeyPress(keys: [.return, .upArrow, .downArrow, .escape, .delete, .tab], phases: .down, action: keyPress)
            .onAppear(perform: load)
            .onChange(of: block.text) { _, new in
                if new != syncedMarkdown { load() }
            }
            .onChange(of: text) { commit() }
            .onChange(of: selection) { publishFormat() }
            .onChange(of: isFocused) { _, focused in focusChanged(focused) }
            .onReceive(FormatCommands.shared.subject) { action in
                if FormatState.shared.activeBlockID == block.uuid && canEdit { apply(action) }
            }
            .onReceive(FormatCommands.shared.wholeBlock) { id, action in
                guard id == block.uuid, canEdit, !text.characters.isEmpty else { return }
                let kept = selection
                selection = AttributedTextSelection(range: text.startIndex..<text.endIndex)
                apply(action, refocus: false)
                selection = kept
            }
            .onChange(of: block.kind_) { rebase() }
            .onReceive(EditorRequests.shared.append) { id, markdown in
                guard id == block.uuid else { return }
                text += RichText.editable(markdown, base: base)
                previous = text
                save()
            }
            .onReceive(SlashMenuState.shared.picked) { id, kind in
                if id == block.uuid { pickFromSlash(kind) }
            }
            .alert("Bağlantı ekle", isPresented: $askingLink) {
                TextField("https://", text: $linkText)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                Button("Ekle") { setLink(linkText) }
                Button("Vazgeç", role: .cancel) {}
            }
    }

    // MARK: - Markdown ↔ editör

    private func load() { load(keepCursor: false) }

    /// Metni Markdown'dan yeniden kur. Tür değişince (yazı tipi değişir) imleç yerinde kalsın.
    private func load(keepCursor: Bool) {
        let offset = cursorOffset
        text = RichText.editable(block.text, base: base)
        previous = text
        syncedMarkdown = block.text
        appliedFont = font
        if isFocused {
            if keepCursor, let offset { placeCursor(offset) } else { selection = AttributedTextSelection(insertionPoint: text.endIndex) }
        }
    }

    /// Tür değişti: karakterlere dokunmadan açık yazı tipi özniteliklerini yeni temele taşı.
    /// (Markdown'dan yeniden kurmak hızlı yazarken henüz kaydedilmemiş harfleri kaydırıyordu.)
    private func rebase() {
        let oldFont = appliedFont ?? font
        appliedFont = font
        let oldResolved = oldFont.resolve(in: fontContext)
        let newBase = base
        // Açık yazı tipi yoksa hiçbir şey yazma: metne / imlece dokunmak hızlı yazımla yarışıp harfleri kaydırır
        guard text.runs[\.font].contains(where: { $0.0 != nil }) else { return }
        text.transform(updating: &selection) { text in
            for (runFont, range) in text.runs[\.font].reversed() {
                guard let runFont else { continue }
                let r = runFont.resolve(in: fontContext)
                let isBold = r.isBold && !oldResolved.isBold
                let isItalic = r.isItalic && !oldResolved.isItalic
                let size: CGFloat? = abs(r.pointSize - oldResolved.pointSize) > 0.5 ? r.pointSize : nil
                // Dönüşümden hemen sonra yeni yazı tipiyle yazılmış harfler: biçimsiz say
                let matchesNew = abs(r.pointSize - newBase.pointSize) < 0.5 && r.isBold == newBase.bold
                    && r.isItalic == newBase.italic && !r.isMonospaced
                guard !matchesNew, isBold || isItalic || r.isMonospaced || size != nil else {
                    text[range].font = nil
                    continue
                }
                var f = size.map { newBase.font(size: $0) } ?? font
                if isBold { f = f.bold() }
                if isItalic { f = f.italic() }
                if r.isMonospaced { f = f.monospaced() }
                text[range].font = f
            }
        }
        previous = text
    }

    private var cursorOffset: Int? {
        switch selection.indices(in: text) {
        case .insertionPoint(let index): text.characters.distance(from: text.startIndex, to: index)
        case .ranges(let ranges): ranges.ranges.first.map { text.characters.distance(from: text.startIndex, to: $0.upperBound) }
        }
    }

    private func save() {
        let markdown = RichText.markdown(from: text, base: font, context: fontContext, environment: environment)
        syncedMarkdown = markdown
        if markdown != block.text { block.text = markdown }
    }

    private func markdown(_ part: AttributedString) -> String {
        RichText.markdown(from: part, base: font, context: fontContext, environment: environment)
    }

    private func focusChanged(_ focused: Bool) {
        if focused {
            FormatState.shared.activeBlockID = block.uuid
            if let offset = FormatState.shared.pendingCursor.removeValue(forKey: block.uuid),
               offset < text.characters.count {
                // Odaklanınca TextEditor imleci kendisi yerleştirir; ardından bizimkini uygula.
                // Bu arada yazılmışsa dokunma (harfler yer değiştirmesin).
                let snapshot = text
                DispatchQueue.main.async { if text == snapshot { placeCursor(offset) } }
            }
            publishFormat()
            updateSlash()
        } else {
            // "+" ile açılıp kullanılmayan "/" temizlensin
            if plain == "/" { text = AttributedString(); previous = text; save() }
            if SlashMenuState.shared.session?.blockID == block.uuid { SlashMenuState.shared.session = nil }
        }
    }

    private func placeCursor(_ offset: Int) {
        let count = text.characters.count
        let index = text.characters.index(text.startIndex, offsetBy: min(max(offset, 0), count))
        selection = AttributedTextSelection(insertionPoint: index)
    }

    // MARK: - Yazma / yapıştırma

    private func commit() {
        // Yalnızca kullanıcı düzenlerken yaz: sayfayı açmak notu "değişti" saymasın
        guard isFocused || formatting else { previous = text; return }
        formatting = false
        let old = previous
        previous = text

        let oldChars = Array(old.characters), newChars = Array(text.characters)
        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count, oldChars[prefix] == newChars[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldChars.count - prefix, suffix < newChars.count - prefix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] { suffix += 1 }
        let inserted = String(newChars[prefix..<(newChars.count - suffix)])

        if !inserted.isEmpty {
            let head = AttributedString(old[old.startIndex..<old.characters.index(old.startIndex, offsetBy: prefix)])
            let tail = AttributedString(old[old.characters.index(old.startIndex, offsetBy: oldChars.count - suffix)..<old.endIndex])

            // "/" menüsü açıkken Enter → vurgulu türü seç
            if inserted == "\n", SlashMenuState.shared.session?.blockID == block.uuid {
                text = head + tail
                previous = text
                SlashMenuState.shared.pickHighlighted()
                return
            }
            if inserted.contains("\n") && !multiline {
                if inserted.filter({ $0 == "\n" }).count == 1 {
                    // Enter (hızlı yazımda birkaç harfle birlikte gelebilir): yeni metni satır sonundan böl
                    let before = inserted.prefix { $0 != "\n" }.count
                    let newline = text.characters.index(text.startIndex, offsetBy: prefix + before)
                    enter(head: AttributedString(text[text.startIndex..<newline]),
                          tail: AttributedString(text[text.characters.index(after: newline)..<text.endIndex]))
                } else {
                    pasteLines(inserted, head: head, tail: tail)
                }
                return
            }
            // Markdown yapıştırma (tek satır): **kalın** gibi işaretler biçime dönüşsün
            if inserted.count > 1, InlineFormat.hasMarkup(inserted) {
                let formatted = RichText.editable(inserted, base: base)
                text = head + formatted + tail
                previous = text
                placeCursor(head.characters.count + formatted.characters.count)
            }
            if inserted.contains(" "), applyMarkdownShortcut(editStart: prefix, editEnd: prefix + inserted.count) { return }
        }
        save()
        updateSlash()
    }

    private func enter(head: AttributedString, tail: AttributedString) {
        let headPlain = String(head.characters)
        if headPlain.isEmpty && !tail.characters.isEmpty {
            // Satır başında Enter: üste boş satır aç, metin bu blokta kalsın
            text = tail
            previous = text
            save()
            onOp(.insertAbove)
            return
        }
        text = head
        previous = text
        save()
        onOp(.split(tail: markdown(tail)))
    }

    private func pasteLines(_ inserted: String, head: AttributedString, tail: AttributedString) {
        var items = MarkdownBlocks.parse(inserted)
        let headMD = markdown(head)
        let tailMD = markdown(tail)
        guard !items.isEmpty else {
            text = head + tail
            previous = text
            save()
            return
        }
        // İlk satır: blok boşsa bu bloğun yerine geçer, değilse metne eklenir
        if String(head.characters).trimmingCharacters(in: .whitespaces).isEmpty {
            let first = items.removeFirst()
            if first.kind != block.kind { onOp(.convert(first.kind)) }
            block.indent = Int64(first.indent)
            if first.isDone { block.setDone(true, by: .human) }
            setMarkdown(first.text)
        } else if items[0].kind == .text {
            setMarkdown(headMD + items.removeFirst().text)
        } else {
            setMarkdown(headMD)
        }
        // Sondaki metin (imleçten sonrası) son satıra eklenir; imleç ondan önce kalır
        var cursor: Int?
        if !tail.characters.isEmpty {
            if let last = items.last, last.kind.hasText, last.kind != .code {
                cursor = RichText.parse(last.text).characters.count
                items[items.count - 1].text += tailMD
            } else if items.isEmpty {
                cursor = RichText.parse(block.text).characters.count
                setMarkdown(block.text + tailMD)
            } else {
                items.append(.init(kind: .text, text: tailMD))
                cursor = 0
            }
        }
        if items.isEmpty {
            placeCursor(cursor ?? text.characters.count)
        } else {
            onOp(.paste(items: items, cursor: cursor))
        }
    }

    /// Bloğun metnini Markdown'dan kur ve kaydet
    private func setMarkdown(_ markdown: String) {
        text = RichText.editable(markdown, base: base)
        previous = text
        syncedMarkdown = markdown
        if block.text != markdown { block.text = markdown }
    }

    /// Satır başına yazılan "# ", "- ", "[] ", "1. ", "> ", "``` ", "--- " → blok türü
    /// Kısayol, yazılan boşluk işaretin hemen arkasına düştüyse uygulanır (hızlı yazımda boşluk başka harflerle gelebilir)
    private func applyMarkdownShortcut(editStart: Int, editEnd: Int) -> Bool {
        guard block.kind == .text else { return false }
        let map: [(String, BlockKind)] = [("### ", .heading3), ("## ", .heading2), ("# ", .heading),
                                         ("[] ", .checklist), ("[ ] ", .checklist), ("- ", .bullet), ("* ", .bullet),
                                         ("1. ", .numbered), ("1) ", .numbered), ("> ", .quote), ("``` ", .code),
                                         ("--- ", .divider)]
        let current = plain
        for (prefix, kind) in map where current.hasPrefix(prefix) && editStart < prefix.count && editEnd >= prefix.count {
            if kind == .divider && current != prefix { continue }
            // İmleç yazılan yerde kalsın: işaretten sonra hızla yazılan harfler de olabilir
            let cursor = max((cursorOffset ?? prefix.count) - prefix.count, 0)
            var rest = text
            rest.removeSubrange(rest.startIndex..<rest.characters.index(rest.startIndex, offsetBy: prefix.count))
            text = rest
            previous = text
            placeCursor(cursor)
            save()
            withAnimation(Theme.spring) { onOp(.convert(kind)) }
            return true
        }
        return false
    }

    // MARK: - "/" menüsü

    private func updateSlash() {
        let menu = SlashMenuState.shared
        let current = plain
        if documentMode, isFocused, current.hasPrefix("/"), !current.contains("\n"), current.count <= 24 {
            let query = String(current.dropFirst())
            if menu.session?.blockID == block.uuid {
                if menu.session?.query != query { menu.session = .init(blockID: block.uuid, query: query) }
            } else {
                menu.session = .init(blockID: block.uuid, query: query)
            }
            if SlashMenuState.filter(query).isEmpty && query.count > 3 { menu.session = nil }
        } else if menu.session?.blockID == block.uuid {
            menu.session = nil
        }
    }

    private func pickFromSlash(_ kind: BlockKind) {
        let fromSlash = SlashMenuState.shared.session?.blockID == block.uuid
        SlashMenuState.shared.session = nil
        // "/sorgu" metnini sil (biçim çubuğundan dönüştürmede metne dokunma)
        if fromSlash && plain.hasPrefix("/") {
            var rest = text
            let end = rest.characters.firstIndex(where: { $0 == " " }) ?? rest.endIndex
            rest.removeSubrange(rest.startIndex..<end)
            text = rest
            previous = text
            save()
        }
        withAnimation(Theme.spring) { onOp(.convert(kind)) }
    }

    // MARK: - Klavye

    private func keyPress(_ press: KeyPress) -> KeyPress.Result {
        let menu = SlashMenuState.shared
        let slashOpen = menu.session?.blockID == block.uuid
        switch press.key {
        case .return:
            if slashOpen { menu.pickHighlighted(); return .handled }
            return .ignored
        case .upArrow:
            if slashOpen { menu.move(-1); return .handled }
            if documentMode, atStart { onOp(.focusPrevious); return .handled }
            return .ignored
        case .downArrow:
            if slashOpen { menu.move(1); return .handled }
            if documentMode, atEnd { onOp(.focusNext); return .handled }
            return .ignored
        case .escape:
            if slashOpen { menu.session = nil; return .handled }
            return .ignored
        case .delete:
            if documentMode, atStart { onOp(.mergeBackward); return .handled }
            return .ignored
        case .tab:
            guard documentMode else { return .ignored }
            onOp(.indent(press.modifiers.contains(.shift) ? -1 : 1))
            return .handled
        default:
            return .ignored
        }
    }

    private var atStart: Bool {
        if case .insertionPoint(let index) = selection.indices(in: text) { return index == text.startIndex }
        return false
    }

    private var atEnd: Bool {
        if case .insertionPoint(let index) = selection.indices(in: text) { return index == text.endIndex }
        return false
    }

    // MARK: - Biçim

    private func publishFormat() {
        guard isFocused else { return }
        let attributes = currentAttributes
        let resolved = (attributes.font ?? font).resolve(in: fontContext)
        FormatState.shared.update(kind: block.kind, bold: resolved.isBold && !base.bold,
                                  italic: resolved.isItalic && !base.italic,
                                  underline: attributes.underlineStyle != nil,
                                  strikethrough: attributes.strikethroughStyle != nil,
                                  code: resolved.isMonospaced, link: attributes.link != nil,
                                  pointSize: Double(resolved.pointSize))
    }

    /// İmleçteki yazma biçimi ya da seçimin ilk parçası
    private var currentAttributes: AttributeContainer {
        if case .ranges = selection.indices(in: text) {
            for container in selection.attributes(in: text) { return container }
        }
        return selection.typingAttributes(in: text)
    }

    private func apply(_ action: FormatAction, refocus: Bool = true) {
        formatting = true
        switch action {
        case .toggle(.bold):
            let on = !all { ($0.font ?? font).resolve(in: fontContext).isBold }
            text.transformAttributes(in: &selection) { $0.font = ($0.font ?? font).bold(on) }
        case .toggle(.italic):
            let on = !all { ($0.font ?? font).resolve(in: fontContext).isItalic }
            text.transformAttributes(in: &selection) { $0.font = ($0.font ?? font).italic(on) }
        case .toggle(.code):
            let on = !all { ($0.font ?? font).resolve(in: fontContext).isMonospaced }
            text.transformAttributes(in: &selection) { $0.font = ($0.font ?? font).monospaced(on) }
        case .toggle(.underline):
            let on = !all { $0.underlineStyle != nil }
            text.transformAttributes(in: &selection) { $0.underlineStyle = on ? .single : nil }
        case .toggle(.strikethrough):
            let on = !all { $0.strikethroughStyle != nil }
            text.transformAttributes(in: &selection) { $0.strikethroughStyle = on ? .single : nil }
        case .toggle(.link):
            let selected = String(text[selection].characters).trimmingCharacters(in: .whitespaces)
            if all({ $0.link != nil }) && !selected.isEmpty {
                text.transformAttributes(in: &selection) { $0.link = nil }
            } else if let url = URL(string: selected), url.scheme?.hasPrefix("http") == true {
                setLink(selected)
            } else if !selected.isEmpty {
                linkText = "https://"
                askingLink = true
            }
        case .highlight(let hex):
            text.transformAttributes(in: &selection) { $0.backgroundColor = hex.map(RichText.fill) }
        case .color(let hex):
            text.transformAttributes(in: &selection) { $0.foregroundColor = hex.map { Color(hex: $0) } }
        case .size(let points):
            setSize { _ in points.map { CGFloat($0) } }
        case .sizeStep(let delta):
            setSize { current in current + CGFloat(delta) }
        case .clear:
            text.transformAttributes(in: &selection) { container in
                container.font = nil
                container.underlineStyle = nil
                container.strikethroughStyle = nil
                container.backgroundColor = nil
                container.foregroundColor = nil
                container.link = nil
            }
        }
        // Biçim çubuğu odağı aldıysa (ör. boyut kutusu) yazmaya geri dön
        if refocus && !isFocused { focus.wrappedValue = block.uuid }
        if !isFocused { save() }
        publishFormat()
    }

    /// Boyutu değiştir; kalın / italik / kod korunur. `points` nil → bloğun normal boyutu
    private func setSize(_ points: @escaping (CGFloat) -> CGFloat?) {
        let base = base
        text.transformAttributes(in: &selection) { container in
            let current = (container.font ?? font).resolve(in: fontContext)
            let target = points(current.pointSize).map { min(max($0, TextSizes.range.lowerBound), TextSizes.range.upperBound) }
            let isBold = current.isBold && !base.bold, isItalic = current.isItalic && !base.italic
            guard let target, abs(target - base.pointSize) > 0.5 else {
                // Normal boyut: yalnızca diğer biçimler kalsın
                var f = font
                if isBold { f = f.bold() }
                if isItalic { f = f.italic() }
                if current.isMonospaced { f = f.monospaced() }
                container.font = isBold || isItalic || current.isMonospaced ? f : nil
                return
            }
            var f = base.font(size: target)
            if isBold { f = f.bold() }
            if isItalic { f = f.italic() }
            if current.isMonospaced { f = f.monospaced() }
            container.font = f
        }
    }

    /// Seçimdeki (ya da imleçteki yazma biçimindeki) her parça koşulu sağlıyor mu
    private func all(_ test: (AttributeContainer) -> Bool) -> Bool {
        if case .ranges = selection.indices(in: text),
           text[selection].characters.contains(where: { !$0.isWhitespace }) {
            var any = false
            for container in selection.attributes(in: text) {
                any = true
                if !test(container) { return false }
            }
            if any { return true }
        }
        return test(selection.typingAttributes(in: text))
    }

    private func setLink(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: value.contains("://") ? value : "https://" + value) else { return }
        formatting = true
        text.transformAttributes(in: &selection) { $0.link = url }
    }
}
