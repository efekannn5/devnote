import SwiftUI
import CoreData
import PhotosUI
import UniformTypeIdentifiers

struct PageEditorView: View {
    @ObservedObject var page: Page
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var persistence: Persistence
    @FocusState private var focus: UUID?
    @State private var showingTeam = false
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importingFile = false
    /// Tuvalde kalemle çizim modu (iPhone / iPad)
    @State private var drawing = false
    /// "/" menüsünden "Görsel" seçilen satır: görseller onun yerine eklenir
    @State private var photoAnchor: Block?

    private var accent: Color { page.notebook?.color ?? .accentColor }

    var body: some View {
        Group {
            switch page.layout {
            case .document:
                DocumentView(page: page, accent: accent, focus: $focus, header: { header })
            case .canvas:
                CanvasView(page: page, accent: accent, focus: $focus, isDrawing: drawing,
                           onDrawingDone: { withAnimation(Theme.spring) { drawing = false } }, header: { header })
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if Self.showsTopFormatBar && persistence.canEdit(page) && !drawing { FormatToolbar() }
        }
        .transition(.opacity)
        .onReceive(EditorRequests.shared.pickPhoto) { id in
            photoAnchor = page.sortedBlocks.first { $0.uuid == id }
            pickingPhotos = true
        }
        .onChange(of: pickingPhotos) { _, picking in
            // Vazgeçildiyse "/görsel" için açılmış boş satırı bırakma
            if !picking && photoItems.isEmpty { photoAnchor = nil }
        }
        .onDisappear { drawing = false }
        .toolbar { toolbar }
        .environment(\.participants, persistence.participants(for: page.notebook))
        .environment(\.canEditPage, persistence.canEdit(page))
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showingTeam) {
            if let nb = page.notebook { TeamView(notebook: nb) }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            // "/" menüsünden açılan boş satır görselle değişsin
            ImageImport.load(items, to: page, after: photoAnchor ?? focusedBlock, replacing: photoAnchor, in: context)
            photoAnchor = nil
            photoItems = []
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var anchor = focusedBlock
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    anchor = ImageImport.add(data, to: page, after: anchor, in: context) ?? anchor
                }
            }
            persistence.save()
        }
    }

    private var focusedBlock: Block? { page.sortedBlocks.first { $0.uuid == focus } }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Başlıksız", text: $page.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .disabled(!persistence.canEdit(page))
                .onChange(of: page.title) { page.touch() }
            HStack(spacing: 10) {
                if let nb = page.notebook {
                    Label(nb.name, systemImage: nb.icon).foregroundStyle(nb.color)
                }
                Text(page.updatedAt, format: .dateTime.day().month(.wide).hour().minute())
                if let nb = page.notebook, persistence.isShared(nb) {
                    let people = persistence.participants(for: nb)
                    if let editor = page.lastEditorName_, editor != persistence.myDisplayName(for: nb) {
                        Label(editor, systemImage: "pencil").help("Son düzenleyen")
                    }
                    Button { showingTeam = true } label: {
                        Label(people.count > 1 ? "\(people.count) kişi" : "Paylaşıldı", systemImage: "person.2.fill")
                    }
                    .buttonStyle(.plain)
                    if !persistence.canEdit(page) {
                        Label("Salt okunur", systemImage: "lock.fill")
                    }
                }
                if !page.tasks.isEmpty {
                    HStack(spacing: 5) {
                        ProgressRing(progress: page.progress, tint: accent, size: 12)
                        Text("\(page.tasks.count - page.openTaskCount)/\(page.tasks.count)")
                            .monospacedDigit()
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(iOS)
        // iPhone'da dar: Ekip ve Sabitle "…" menüsünde (düğmeler birbirine girmesin).
        // Görünüm (Belge / Tuval) not oluşturulurken seçilir; düzenlerken değişmez.
        ToolbarItemGroup(placement: .primaryAction) {
            if page.layout == .canvas && persistence.canEdit(page) {
                Button {
                    if !drawing { focus = nil }
                    withAnimation(Theme.spring) { drawing.toggle() }
                } label: {
                    Label(drawing ? "Çizimi bitir" : "Çiz", systemImage: drawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                }
            }

            if !drawing { addMenu }

            Menu {
                if Persistence.cloudEnabled, page.notebook != nil {
                    Button("Ekip ve Davet", systemImage: "person.2") { showingTeam = true }
                }
                Button(page.isPinned ? "Sabitlemeyi Kaldır" : "Sabitle", systemImage: page.isPinned ? "pin.slash" : "pin") {
                    withAnimation(Theme.spring) { page.isPinned.toggle() }
                }
                if page.drawing_ != nil && persistence.canEdit(page) {
                    Button("Çizimi Temizle", systemImage: "scribble", role: .destructive) {
                        page.drawing_ = nil
                        page.touch()
                        persistence.save()
                    }
                }
            } label: {
                Label("Diğer", systemImage: "ellipsis")
            }
        }
        #else
        ToolbarItemGroup(placement: .primaryAction) {
            if Persistence.cloudEnabled, page.notebook != nil {
                Button { showingTeam = true } label: {
                    Label("Ekip", systemImage: "person.2")
                }
                .help("Ekip, davet ve görev atama")
            }
            addMenu

            if page.layout == .canvas && page.drawing_ != nil && persistence.canEdit(page) {
                Button {
                    focus = nil
                    withAnimation(Theme.spring) { drawing.toggle() }
                } label: {
                    Label(drawing ? "Düzenlemeyi Bitir" : "Çizimi Düzenle",
                          systemImage: drawing ? "checkmark.circle.fill" : "scribble.variable")
                }
                .help("Çizgileri seç, taşı ya da sil")
            }

            Button {
                withAnimation(Theme.spring) { page.isPinned.toggle() }
            } label: {
                Label("Sabitle", systemImage: page.isPinned ? "pin.fill" : "pin")
            }
        }
        #endif
        #if os(iOS)
        ToolbarItemGroup(placement: .keyboard) {
            if !Self.showsTopFormatBar {
                // iPhone: blok ekle + tür + biçimler tek kaydırılabilir satırda
                Menu {
                    ForEach(page.layout == .document ? BlockKind.insertable : BlockKind.textKinds) { kind in
                        Button(kind.title, systemImage: kind.symbol) { addFromKeyboard(kind) }
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("Blok ekle")
                BlockKindPicker(compact: true)
                FormatBar()
                Spacer()
            }
            Button { focus = nil } label: { Image(systemName: "keyboard.chevron.compact.down") }
                .accessibilityLabel("Klavyeyi kapat")
        }
        #endif
    }

    /// Mac ve iPad'de Word gibi üstte biçim çubuğu; iPhone'da klavyenin üstünde
    #if os(iOS)
    static var showsTopFormatBar: Bool { UIDevice.current.userInterfaceIdiom != .phone }
    #else
    static let showsTopFormatBar = true
    #endif

    /// Klavye çubuğundaki "+": odaktaki satırın altına seçilen türde blok
    private func addFromKeyboard(_ kind: BlockKind) {
        let ops = BlockOps(page: page, context: context, focus: $focus)
        if let current = focusedBlock, page.layout == .document {
            if current.kind == .text && current.text.isEmpty && kind != .image {
                ops.perform(.convert(kind), on: current)
                return
            }
            let new = withAnimation(Theme.spring) { page.addBlock(.text, after: current, in: context) }
            new.indent = current.indent
            if kind == .text { ops.focusBlock(new, cursor: 0) } else { ops.perform(.convert(kind), on: new) }
        } else if kind == .image {
            pickingPhotos = true
        } else {
            add(kind)
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(BlockKind.textKinds) { kind in
                Button(kind.title, systemImage: kind.symbol) { add(kind) }
            }
            Divider()
            Button("Fotoğraf…", systemImage: "photo.on.rectangle") { pickingPhotos = true }
            #if os(macOS)
            Button("Dosyadan Görsel…", systemImage: "folder") { importingFile = true }
            #endif
        } label: {
            Label("Ekle", systemImage: "plus")
        }
        .disabled(!persistence.canEdit(page))
    }

    private func add(_ kind: BlockKind) {
        let after = page.sortedBlocks.first { $0.uuid == focus }
        let block = withAnimation(Theme.spring) { page.addBlock(kind, after: after, in: context) }
        if page.layout == .canvas {
            // Görünen alanın sol üstüne yakın, üst üste binmesin diye biraz kaydır
            let n = Double(page.sortedBlocks.count)
            block.place(x: 40 + n.truncatingRemainder(dividingBy: 6) * 24,
                        y: 20 + n.truncatingRemainder(dividingBy: 6) * 24)
        }
        focus = block.uuid
    }
}

// MARK: - Belge modu (Notion gibi bloklar)

struct DocumentView<Header: View>: View {
    var page: Page
    var accent: Color
    var focus: FocusState<UUID?>.Binding
    @ViewBuilder var header: () -> Header
    @Environment(\.managedObjectContext) private var context
    @Environment(\.canEditPage) private var canEdit
    @State private var dropTarget: UUID?
    @State private var hovered: UUID?
    @State private var menuBlock: UUID?
    @State private var commentBlock: Block?

    private var ops: BlockOps { BlockOps(page: page, context: context, focus: focus) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                header().padding(.bottom, 18)
                ForEach(page.sortedBlocks) { block in
                    BlockRow(block: block, accent: accent, focus: focus,
                             onOp: { ops.perform($0, on: block) },
                             onDelete: { delete(block) })
                    .padding(.leading, Self.gutter)
                    .overlay(alignment: .topLeading) {
                        if canEdit { gutter(block) }
                    }
                    #if os(macOS)
                    .overlay(alignment: .bottomLeading) {
                        SlashMenuView(blockID: block.uuid)
                            .padding(.leading, Self.gutter + CGFloat(block.indent) * 22)
                            .alignmentGuide(.bottom) { $0[.top] - 4 }
                    }
                    #endif
                    .overlay(alignment: .top) {
                        if dropTarget == block.uuid {
                            Capsule().fill(accent).frame(height: 3).offset(y: -3)
                                .padding(.leading, Self.gutter)
                                .transition(.opacity)
                        }
                    }
                    // "/" menüsü sonraki satırların üstünde kalsın
                    .zIndex(focus.wrappedValue == block.uuid ? 1 : 0)
                    .onHover { inside in hovered = inside ? block.uuid : (hovered == block.uuid ? nil : hovered) }
                    .dropDestination(for: String.self) { items, _ in
                        moveDropped(items, before: block)
                    } isTargeted: { targeted in
                        withAnimation(Theme.spring) {
                            if targeted { dropTarget = block.uuid } else if dropTarget == block.uuid { dropTarget = nil }
                        }
                    }
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                            removal: .opacity))
                }
                if canEdit { addBlockButton.padding(.leading, Self.gutter).padding(.top, 6) }
                // Sayfanın altına tıklayınca yeni satır (sürüklenen blok buraya bırakılırsa sona gider)
                Color.clear
                    .frame(height: 160)
                    .contentShape(Rectangle())
                    .onTapGesture { appendIfNeeded() }
                    .dropDestination(for: String.self) { items, _ in moveDropped(items, before: nil) }
            }
            .frame(maxWidth: 760 + Self.gutter, alignment: .leading)
            .padding(.leading, max(Layout.margin - Self.gutter, 4))
            .padding(.trailing, Layout.margin)
            .padding(.top, Layout.margin / 1.5)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        #if os(iOS)
        // iPhone: "/" menüsü klavyenin hemen üstünde
        .safeAreaInset(edge: .bottom) {
            SlashMenuView()
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .animation(Theme.spring, value: SlashMenuState.shared.session?.blockID)
        }
        #endif
        .dropDestination(for: DroppedImage.self) { images, _ in
            guard canEdit else { return false }
            var anchor = page.sortedBlocks.last
            for image in images {
                anchor = ImageImport.add(image.data, to: page, after: anchor, in: context) ?? anchor
            }
            Persistence.shared.save()
            return !images.isEmpty
        }
        .sheet(item: $commentBlock) { CommentsSheet(block: $0) }
        .onDisappear { SlashMenuState.shared.session = nil }
    }

    #if os(iOS)
    private static var gutter: CGFloat { 26 }
    #else
    private static var gutter: CGFloat { 44 }
    #endif

    /// Satırın solu: Mac'te üzerine gelince "+" ve "⋮⋮"; iPhone'da hep soluk "⋮⋮".
    /// "+" altına yeni satır açıp "/" menüsünü gösterir; "⋮⋮" sürükleyerek taşır, dokununca blok menüsü.
    private func gutter(_ block: Block) -> some View {
        let visible = hovered == block.uuid || menuBlock == block.uuid
        return HStack(spacing: 0) {
            #if os(macOS)
            Button { insertWithSlash(after: block) } label: {
                Image(systemName: "plus")
                    .font(.callout.weight(.medium))
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Altına blok ekle")
            #endif
            Button { menuBlock = block.uuid } label: {
                Image(systemName: "circle.grid.2x3.fill")
                    .font(.system(size: Self.handleSymbolSize, weight: .bold))
                    .frame(width: Self.handleWidth, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Blok menüsü")
            .accessibilityIdentifier("block-handle")
            .help("Sürükle: taşı · Tıkla: menü")
            .draggable(DragPayload.prefix + block.uuid.uuidString) {
                Label(block.text.isEmpty ? block.kind.title : block.text, systemImage: block.kind.symbol)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .popover(isPresented: Binding(get: { menuBlock == block.uuid },
                                          set: { if !$0 && menuBlock == block.uuid { menuBlock = nil } })) {
                BlockMenu(block: block,
                          onOp: { ops.perform($0, on: block) },
                          onDuplicate: { ops.duplicate(block) },
                          onComment: { commentBlock = block },
                          onDelete: { delete(block) })
                    .presentationCompactAdaptation(.popover)
            }
        }
        .foregroundStyle(.secondary)
        #if os(macOS)
        .opacity(visible ? 0.9 : 0)
        #else
        // iPhone: yalnızca yazılan satırda (ekran sade kalsın; diğer satırlarda basılı tutunca menü var)
        .opacity(visible || focus.wrappedValue == block.uuid ? 1 : 0)
        #endif
        .padding(.leading, Self.gutter - Self.gutterButtonsWidth + CGFloat(block.indent) * 22 - 4)
        .padding(.top, gutterTop(block))
    }

    #if os(iOS)
    private static var handleWidth: CGFloat { 22 }
    private static var handleSymbolSize: CGFloat { 13 }
    private static var gutterButtonsWidth: CGFloat { 22 }
    #else
    private static var handleWidth: CGFloat { 16 }
    private static var handleSymbolSize: CGFloat { 10 }
    private static var gutterButtonsWidth: CGFloat { 36 }
    #endif

    /// Tutamaç ilk satırın ortasında dursun
    private func gutterTop(_ block: Block) -> CGFloat {
        switch block.kind {
        case .heading: 18
        case .heading2: 12
        case .heading3: 7
        case .divider: 2
        case .code: 6
        default: 0
        }
    }

    /// Sayfa sonundaki "+ Blok ekle": dokununca tür menüsü
    private var addBlockButton: some View {
        Menu {
            ForEach(BlockKind.insertable) { kind in
                Button(kind.title, systemImage: kind.symbol) { append(kind) }
            }
        } label: {
            Label("Blok ekle", systemImage: "plus")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("add-block")
    }

    private func append(_ kind: BlockKind) {
        let last = page.sortedBlocks.last
        // Sondaki boş metin satırı varsa onu kullan
        let block = if let last, last.kind == .text, last.text.isEmpty { last }
                    else { withAnimation(Theme.spring) { page.addBlock(.text, after: last, in: context) } }
        block.indent = 0
        if kind == .text {
            ops.focusBlock(block, cursor: 0)
        } else {
            ops.perform(.convert(kind), on: block)
        }
    }

    private func insertWithSlash(after block: Block) {
        let new: Block
        if block.kind == .text && block.text.isEmpty {
            new = block
            new.text = "/"
        } else {
            new = withAnimation(Theme.spring) { page.addBlock(.text, text: "/", after: block, in: context) }
            new.indent = block.indent
        }
        ops.focusBlock(new, cursor: Int.max)
    }

    private func moveDropped(_ items: [String], before target: Block?) -> Bool {
        dropTarget = nil
        guard canEdit, let id = items.first.flatMap(DragPayload.uuid(from:)),
              let block = page.sortedBlocks.first(where: { $0.uuid == id }), block != target else { return false }
        withAnimation(Theme.spring) { page.move(block, before: target) }
        return true
    }

    private func appendIfNeeded() {
        guard canEdit else { return }
        if let last = page.sortedBlocks.last, last.kind.hasText, last.kind != .image, last.text.isEmpty {
            ops.focusBlock(last, cursor: 0)
        } else {
            let new = withAnimation(Theme.spring) { page.addBlock(.text, in: context) }
            new.indent = 0
            focus.wrappedValue = new.uuid
        }
    }

    private func delete(_ block: Block) {
        if menuBlock == block.uuid { menuBlock = nil }
        withAnimation(Theme.spring) { context.delete(block) }
    }
}

// MARK: - Tuval modu (OneNote tarzı serbest yerleşim)

struct CanvasView<Header: View>: View {
    var page: Page
    var accent: Color
    var focus: FocusState<UUID?>.Binding
    var isDrawing: Bool = false
    var onDrawingDone: () -> Void = {}
    @ViewBuilder var header: () -> Header
    @Environment(\.managedObjectContext) private var context

    private let canvasSize = CGSize(width: 3000, height: 2400)
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollGeometry: ScrollGeometry?

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                // Başlık tuvalin üstünde ayrı durur; bloklar asla üstüne binmez
                header()
                    .frame(maxWidth: 600, alignment: .leading)
                    .padding(.horizontal, Layout.margin)
                    .padding(.top, 24)
                    .padding(.bottom, 8)

                ZStack(alignment: .topLeading) {
                    DotGrid()
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            tapCanvas(at: location)
                        }

                    ForEach(page.sortedBlocks) { block in
                        CanvasCard(block: block, accent: accent, focus: focus,
                                   onOp: { BlockOps(page: page, context: context, focus: focus).perform($0, on: block) },
                                   onDelete: { delete(block) })
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }

                }
                .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
                .coordinateSpace(.named(CanvasCard.space))
            }
            // Çizim kartların üstünde; koordinatları kaydırma içeriğinin koordinatları
            .overlay(alignment: .topLeading) {
                #if os(macOS)
                if isDrawing {
                    MacDrawingEditor(page: page, onDone: onDrawingDone)
                } else {
                    DrawingImage(page: page)
                }
                #else
                if !isDrawing { DrawingImage(page: page) }
                #endif
            }
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, new in scrollGeometry = new }
        #if os(iOS)
        .overlay {
            if isDrawing, let scrollGeometry {
                DrawingCanvas(page: page, geometry: scrollGeometry) { offset in
                    scrollPosition.scrollTo(point: offset)
                }
                .ignoresSafeArea()
            }
        }
        #endif
        .scrollDisabled(isDrawing)   // tek parmak çizsin; iki parmakla kaydırmayı çizim katmanı yapar
        .onAppear(perform: arrangeUnplaced)
        .onChange(of: page.sortedBlocks.count) { arrangeUnplaced() }
        .onChange(of: focus.wrappedValue) { old, _ in
            cleanupEmpty(old)
        }
    }

    /// Belge modundan gelen ya da MCP ile eklenen (konumsuz) blokları,
    /// yerleşmiş blokların altına sırayla dizer.
    private func arrangeUnplaced() {
        let blocks = page.sortedBlocks
        let unplaced = blocks.filter { !$0.isPlaced }
        guard !unplaced.isEmpty else { return }
        var y = blocks.filter(\.isPlaced).map { $0.y + $0.estimatedCanvasHeight }.max().map { $0 + 16 } ?? 8
        for block in unplaced {
            block.width = max(block.width, Layout.defaultCardWidth)
            block.place(x: Layout.margin - 12 + Double(block.indent) * 22, y: y)
            y += block.estimatedCanvasHeight + 6
        }
    }

    private func tapCanvas(at point: CGPoint) {
        // Odak varsa önce odağı bırak; yoksa tıklanan yere yeni kutu aç
        if focus.wrappedValue != nil {
            focus.wrappedValue = nil
            return
        }
        let block = withAnimation(Theme.spring) { page.addBlock(.text, in: context) }
        block.place(x: point.x - 14, y: point.y - 14)
        focus.wrappedValue = block.uuid
    }

    /// Tuvalde boş bırakılan metin kutularını temizle
    private func cleanupEmpty(_ id: UUID?) {
        // Biçim çubuğundaki boyut kutusuna geçildiyse kutu silinmesin
        guard !FormatState.shared.editingToolbar,
              let id, let block = page.sortedBlocks.first(where: { $0.uuid == id }),
              block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              block.kind == .text else { return }
        withAnimation(Theme.spring) { context.delete(block) }
    }

    private func delete(_ block: Block) {
        withAnimation(Theme.spring) { context.delete(block) }
    }
}

struct CanvasCard: View {
    @ObservedObject var block: Block
    var accent: Color
    var focus: FocusState<UUID?>.Binding
    var onOp: (EditorOp) -> Void = { _ in }
    var onDelete: () -> Void

    @State private var drag: CGSize = .zero
    @State private var resize: CGFloat = 0
    @State private var hovering = false

    private var isFocused: Bool { focus.wrappedValue == block.uuid }
    private var active: Bool { hovering || isFocused || drag != .zero }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Taşıma tutamacı
            Capsule()
                .fill(.secondary.opacity(active ? 0.5 : Self.idleHandleOpacity))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .frame(height: Self.handleHeight)
                .contentShape(Rectangle())
                .accessibilityIdentifier("canvas-handle")
                // Kaydırmayla yarışmasın: tutamaçtan başlayan sürükleme her zaman kartı taşır
                .highPriorityGesture(moveGesture)
                #if os(macOS)
                .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                #endif

            BlockRow(block: block, accent: accent, focus: focus, documentMode: false,
                     onOp: onOp, onDelete: onDelete)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .frame(width: max(140, block.width + resize), alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.opacity(active ? 1 : 0.0001))
                .shadow(color: .black.opacity(active ? 0.12 : 0), radius: drag == .zero ? 8 : 18, y: drag == .zero ? 2 : 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isFocused ? accent.opacity(0.6) : .secondary.opacity(active ? 0.2 : 0), lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            // Genişlik tutamacı
            Image(systemName: "arrow.left.and.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(5)
                .opacity(active ? 1 : 0)
                .contentShape(Rectangle())
                .highPriorityGesture(resizeGesture)
        }
        .scaleEffect(drag == .zero ? 1 : 1.02)
        .animation(Theme.spring, value: active)
        // Konum animasyonsuz: kart parmağı / imleci birebir izlesin
        .offset(x: block.x + drag.width, y: block.y + drag.height)
        .onHover { hovering = $0 }
    }

    /// Sürükleme tuvalin sabit koordinatlarında ölçülür. (Yerel koordinat kartla birlikte kaydığı için
    /// kart parmağın gerisinde kalıp titreyerek ilerliyordu.)
    static let space = "canvas"
    #if os(iOS)
    // Dokunmatikte üzerine gelme yok: tutamaç hep hafifçe görünsün ve parmakla tutulacak kadar büyük olsun
    private static let idleHandleOpacity = 0.25
    private static let handleHeight: CGFloat = 26
    #else
    private static let idleHandleOpacity = 0.0
    private static let handleHeight: CGFloat = 14
    #endif

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { drag = value.translation }
            }
            .onEnded { value in
                block.place(x: block.x + value.translation.width, y: block.y + value.translation.height)
                drag = .zero
                block.page?.touch()
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { resize = $0.translation.width }
            .onEnded { value in
                block.width = max(140, block.width + value.translation.width)
                resize = 0
            }
    }
}

/// Tuval arka planı: ince nokta ızgarası
struct DotGrid: View {
    var spacing: CGFloat = 22

    var body: some View {
        Canvas { ctx, size in
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 1.6, height: 1.6))
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    ctx.fill(dot.offsetBy(dx: x, dy: y), with: .color(.secondary.opacity(0.25)))
                    x += spacing
                }
                y += spacing
            }
        }
    }
}

enum Layout {
    #if os(iOS)
    static let margin: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 20 : 40
    #else
    static let margin: CGFloat = 48
    #endif

    #if os(iOS)
    static let defaultCardWidth: Double = UIDevice.current.userInterfaceIdiom == .phone ? 340 : 420
    #else
    static let defaultCardWidth: Double = 420
    #endif
}

/// Belge içinde sürüklenen bloğun kimliği (dışarıdan gelen düz metinle karışmasın diye önekli)
enum DragPayload {
    static let prefix = "devnote-block:"
    static func uuid(from string: String) -> UUID? {
        string.hasPrefix(prefix) ? UUID(uuidString: String(string.dropFirst(prefix.count))) : nil
    }
}

/// Sayfaya bırakılan görsel (Finder, Fotoğraflar, Safari…)
struct DroppedImage: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { DroppedImage(data: $0) }
    }
}
