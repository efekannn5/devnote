import SwiftUI
import PencilKit

// Tuvalin serbest çizimi. Çizim sayfada (`drawing_`) PencilKit verisi olarak saklanır ve diğer alanlar gibi
// iCloud / yakın cihazla eşitlenir. Koordinatlar tuval kaydırma içeriğinin koordinatlarıdır.

/// Çizimin hafif görüntüsü (çizim modu dışında, Mac'te her zaman). İçeriğin sol üstüne hizalanır.
struct DrawingImage: View {
    @ObservedObject var page: Page

    var body: some View {
        if let data = page.drawing_, let image = Self.render(data, key: page.uuid) {
            Image(platformImage: image.image)
                .resizable()
                .frame(width: image.rect.width, height: image.rect.height)
                .offset(x: image.rect.minX, y: image.rect.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private static let cache = NSCache<NSString, Rendered>()
    final class Rendered { let image: PlatformImage; let rect: CGRect
        init(image: PlatformImage, rect: CGRect) { self.image = image; self.rect = rect } }

    static func render(_ data: Data, key: UUID) -> Rendered? {
        let cacheKey = "\(key)-\(data.hashValue)" as NSString
        if let hit = cache.object(forKey: cacheKey) { return hit }
        guard let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty else { return nil }
        let rect = drawing.bounds.insetBy(dx: -4, dy: -4)
        // Bellek sınırı: en uzun kenar en fazla 4096 piksel
        let scale = min(2, 4096 / max(rect.width, rect.height, 1))
        let rendered = Rendered(image: drawing.image(from: rect, scale: scale), rect: rect)
        cache.setObject(rendered, forKey: cacheKey)
        return rendered
    }
}

#if os(iOS)
/// Çizim modunda tuvalin görünen kısmını kaplayan PencilKit katmanı.
/// Tek parmak / Pencil çizer, iki parmak kaydırır; kaydırma alttaki tuvale aktarılır.
struct DrawingCanvas: UIViewRepresentable {
    @ObservedObject var page: Page
    let geometry: ScrollGeometry
    var onScroll: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(page: page, onScroll: onScroll) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentSize = geometry.contentSize
        let insets = geometry.contentInsets
        canvas.contentInset = UIEdgeInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing)
        canvas.contentOffset = geometry.contentOffset
        context.coordinator.lastData = page.drawing_
        canvas.drawing = page.drawing_.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
        canvas.delegate = context.coordinator

        let picker = context.coordinator.picker
        picker.addObserver(canvas)
        picker.setVisible(true, forFirstResponder: canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.contentSize != geometry.contentSize { canvas.contentSize = geometry.contentSize }
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        coordinator.picker.setVisible(false, forFirstResponder: canvas)
        canvas.resignFirstResponder()
        coordinator.saveNow(canvas)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let page: Page
        let onScroll: (CGPoint) -> Void
        let picker = PKToolPicker()
        var lastData: Data?
        private var pendingSave: Task<Void, Never>?

        init(page: Page, onScroll: @escaping (CGPoint) -> Void) {
            self.page = page
            self.onScroll = onScroll
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            onScroll(scrollView.contentOffset)
        }

        func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
            // Her çizgide değil, kısa bir duraksamada kaydet
            pendingSave?.cancel()
            pendingSave = Task { @MainActor [weak self, weak canvas] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self, let canvas else { return }
                saveNow(canvas)
            }
        }

        @MainActor
        func saveNow(_ canvas: PKCanvasView) {
            pendingSave?.cancel()
            let data: Data? = canvas.drawing.strokes.isEmpty ? nil : canvas.drawing.dataRepresentation()
            guard data != lastData else { return }
            lastData = data
            page.drawing_ = data
            page.touch()
            Persistence.shared.save()
        }
    }
}
#endif

#if os(macOS)
/// Mac'te çizimi düzenleme: çizgiye tıkla ya da alan çizerek seç, sürükleyerek taşı, ⌫ ile sil.
/// (Mac'te PencilKit'in çizim tuvali yok; çizgiler iPhone / iPad'de çizilir.)
struct MacDrawingEditor: View {
    @ObservedObject var page: Page
    var onDone: () -> Void

    @State private var drawing = PKDrawing()
    @State private var selection: Set<Int> = []
    @State private var dragOffset: CGSize = .zero
    @State private var marquee: CGRect?
    @State private var mode: DragMode?
    @FocusState private var focused: Bool

    private enum DragMode { case move, marquee }

    private var selectedBounds: CGRect? {
        let rects = selection.compactMap { drawing.strokes.indices.contains($0) ? drawing.strokes[$0].renderBounds : nil }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -6, dy: -6)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Tıklamaları yakalayan şeffaf zemin (içeriğin tamamı)
            Color.white.opacity(0.001)
                .gesture(dragGesture)

            strokesImage(selected: false)
            strokesImage(selected: true)
                .offset(dragOffset)

            if let rect = selectedBounds {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX + dragOffset.width, y: rect.minY + dragOffset.height)
                    .allowsHitTesting(false)
            }
            if let marquee {
                Rectangle()
                    .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .background(Color.secondary.opacity(0.08))
                    .frame(width: marquee.width, height: marquee.height)
                    .offset(x: marquee.minX, y: marquee.minY)
                    .allowsHitTesting(false)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onDeleteCommand(perform: deleteSelection)
        .onExitCommand(perform: onDone)
        .onKeyPress(.delete) { deleteSelection(); return .handled }
        .onAppear {
            drawing = page.drawing_.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
            focused = true
        }
        .overlay(alignment: .topLeading) { hint }
    }

    private var hint: some View {
        Text(selection.isEmpty ? "Çizgiye tıkla ya da alan seç · Esc: bitir"
                               : "\(selection.count) çizgi seçili · sürükle: taşı · ⌫: sil · Esc: bitir")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
            .padding(8)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func strokesImage(selected: Bool) -> some View {
        let strokes = drawing.strokes.enumerated().filter { selection.contains($0.offset) == selected }.map(\.element)
        if !strokes.isEmpty {
            let part = PKDrawing(strokes: strokes)
            let rect = part.bounds.insetBy(dx: -4, dy: -4)
            let scale = min(2, 4096 / max(rect.width, rect.height, 1))
            Image(nsImage: part.image(from: rect, scale: scale))
                .resizable()
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if mode == nil {
                    focused = true
                    if let rect = selectedBounds, rect.contains(value.startLocation) {
                        mode = .move
                    } else if let hit = stroke(at: value.startLocation) {
                        selection = [hit]
                        mode = .move
                    } else {
                        selection = []
                        mode = .marquee
                    }
                }
                switch mode {
                case .move: dragOffset = value.translation
                case .marquee: marquee = CGRect(origin: value.startLocation, size: .zero)
                    .union(CGRect(origin: value.location, size: .zero))
                case nil: break
                }
            }
            .onEnded { value in
                defer { mode = nil; marquee = nil; dragOffset = .zero }
                switch mode {
                case .move:
                    let d = value.translation
                    guard abs(d.width) + abs(d.height) > 0.5 else { return }
                    let move = CGAffineTransform(translationX: d.width, y: d.height)
                    for index in selection where drawing.strokes.indices.contains(index) {
                        drawing.strokes[index].transform = drawing.strokes[index].transform.concatenating(move)
                    }
                    save()
                case .marquee:
                    if let rect = marquee, rect.width > 3 || rect.height > 3 {
                        selection = Set(drawing.strokes.indices.filter { drawing.strokes[$0].renderBounds.intersects(rect) })
                    }
                case nil: break
                }
            }
    }

    /// Noktaya en yakın çizgi (çizgi kalınlığı + birkaç punto tolerans)
    private func stroke(at point: CGPoint) -> Int? {
        for index in drawing.strokes.indices.reversed() {
            let stroke = drawing.strokes[index]
            guard stroke.renderBounds.insetBy(dx: -8, dy: -8).contains(point) else { continue }
            for sample in stroke.path.interpolatedPoints(by: .distance(3)) {
                let location = sample.location.applying(stroke.transform)
                let tolerance = max(sample.size.width, sample.size.height) / 2 + 6
                if hypot(location.x - point.x, location.y - point.y) <= tolerance { return index }
            }
        }
        return nil
    }

    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        drawing.strokes = drawing.strokes.enumerated().filter { !selection.contains($0.offset) }.map(\.element)
        selection = []
        save()
    }

    private func save() {
        page.drawing_ = drawing.strokes.isEmpty ? nil : drawing.dataRepresentation()
        page.touch()
        Persistence.shared.save()
    }
}
#endif
