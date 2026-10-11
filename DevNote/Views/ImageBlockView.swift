import SwiftUI
import PhotosUI
import CoreData

/// Görsel bloğu: fotoğraf + altında açıklama. Dokununca tam ekran açılır.
struct ImageBlockView: View {
    @ObservedObject var block: Block
    var focus: FocusState<UUID?>.Binding
    var canEdit: Bool
    @State private var showingViewer = false

    private var image: PlatformImage? {
        guard let data = block.imageData_ else { return nil }
        let stamp = block.modifiedAt_?.timeIntervalSinceReferenceDate ?? 0
        return ImageCodec.image(data, key: "\(block.uuid)-\(data.count)-\(stamp)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 460, alignment: .leading)
                    // Tuvalde yükseklik serbest; görselin oranından fazla yer kaplayıp üstte boşluk bırakmasın
                    .fixedSize(horizontal: false, vertical: true)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
                    .contentShape(Rectangle())
                    .onTapGesture { showingViewer = true }
                    .accessibilityLabel(block.text.isEmpty ? "Görsel" : block.text)
            } else {
                // iCloud'dan henüz gelmedi ya da açılamadı
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                    .frame(height: 160)
                    .overlay {
                        Label(block.imageData_ == nil ? "Görsel bekleniyor…" : "Görsel açılamadı", systemImage: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
            TextField("Açıklama ekle", text: $block.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .focused(focus, equals: block.uuid)
                .disabled(!canEdit)
                .onChange(of: block.text) { block.page?.touch() }
        }
        .padding(.vertical, 4)
        #if os(iOS)
        .fullScreenCover(isPresented: $showingViewer) { viewer }
        #else
        .sheet(isPresented: $showingViewer) { viewer.frame(minWidth: 700, minHeight: 520) }
        #endif
    }

    @ViewBuilder
    private var viewer: some View {
        if let image { ImageViewer(image: image, caption: block.text) }
    }
}

/// Tam ekran görsel: iki parmakla yakınlaştır, paylaş.
struct ImageViewer: View {
    let image: PlatformImage
    let caption: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        NavigationStack {
            Image(platformImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(MagnifyGesture()
                    .onChanged { scale = max(1, min(6, lastScale * $0.magnification)) }
                    .onEnded { _ in lastScale = scale })
                .onTapGesture(count: 2) {
                    withAnimation(Theme.spring) { scale = scale > 1 ? 1 : 2.5; lastScale = scale }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .navigationTitle(caption)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.black, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Kapat") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        let shared = Image(platformImage: image)
                        ShareLink(item: shared, preview: SharePreview(caption.isEmpty ? "Görsel" : caption, image: shared))
                    }
                }
        }
    }
}

/// Seçilen / bırakılan görseli sayfaya ekler.
@MainActor
enum ImageImport {
    static func add(_ data: Data, to page: Page, after: Block?, in context: NSManagedObjectContext) -> Block? {
        guard let jpeg = ImageCodec.compress(data) else {
            ErrorReporter.shared.report(message: "Görsel okunamadı", area: "Görsel")
            return nil
        }
        let block = withAnimation(Theme.spring) { page.addBlock(.image, after: after, in: context) }
        block.imageData_ = jpeg
        if page.layout == .canvas {
            block.width = 320
            let n = Double(page.sortedBlocks.count)
            block.place(x: 40 + n.truncatingRemainder(dividingBy: 6) * 24, y: 20 + n.truncatingRemainder(dividingBy: 6) * 24)
        }
        return block
    }

    /// `replacing`: görseller eklendikten sonra silinecek boş satır ("/" menüsünden açılan)
    static func load(_ items: [PhotosPickerItem], to page: Page, after: Block?, replacing: Block? = nil,
                     in context: NSManagedObjectContext) {
        Task {
            var anchor = after
            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    anchor = add(data, to: page, after: anchor, in: context) ?? anchor
                } catch {
                    ErrorReporter.shared.report(error, area: "Görsel")
                }
            }
            if let replacing, anchor != replacing, !replacing.isDeleted,
               replacing.kind == .text, replacing.text.isEmpty {
                context.delete(replacing)
            }
            Persistence.shared.save()
        }
    }
}
