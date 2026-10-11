import SwiftUI
import CoreData

enum SidebarItem: Hashable {
    case all, pinned, openTasks, assignedToMe, aiCompleted
    case notebook(Notebook)

    var title: String {
        switch self {
        case .all: "Tüm Notlar"
        case .pinned: "Sabitlenenler"
        case .openTasks: "Açık Görevler"
        case .assignedToMe: "Bana Atananlar"
        case .aiCompleted: "AI Tamamladı"
        case .notebook(let nb): nb.name
        }
    }
}

struct RootView: View {
    @State private var sidebar: SidebarItem? = .all
    @State private var selectedPage: Page?
    @State private var search = ""
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(selection: $sidebar)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } content: {
            PageListView(filter: sidebar ?? .all, search: search, selection: $selectedPage)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
        } detail: {
            if let page = selectedPage, !page.isDeleted, page.managedObjectContext != nil {
                PageEditorView(page: page)
                    .id(page.uuid)
            } else {
                ContentUnavailableView("Bir not seç", systemImage: "note.text",
                                       description: Text("Soldan bir sayfa seç ya da yenisini oluştur."))
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Notlarda ara")
        .onChange(of: sidebar) { selectedPage = nil }
        .errorBanner()
        .onOpenURL(perform: open)
        #if DEBUG
        .task {
            // DEVNOTE_DEBUG_ACTION=schema|assign|… ile başlatınca (URL açamayan ortamlar için)
            if let action = ProcessInfo.processInfo.environment["DEVNOTE_DEBUG_ACTION"] {
                try? await Task.sleep(for: .seconds(4))
                DemoData.run(action)
            }
        }
        #endif
        .onReceive(TaskNotifier.shared.$openTaskRequest.compactMap { $0 }) { id in
            if let url = URL(string: "devnote://task/\(id)") { open(url) }
        }
    }

    /// devnote://page/<uuid>, devnote://task/<uuid> (Dynamic Island ve bildirimlerden)
    private func open(_ url: URL) {
        guard url.scheme == "devnote", let host = url.host() else { return }
        let id = url.pathComponents.dropFirst().first ?? ""
        #if DEBUG
        if host == "debug" { DemoData.run(id); return }
        #endif
        let page: Page? = switch host {
        case "task": TaskActions.block(id)?.page
        case "page": UUID(uuidString: id).flatMap { uuid in
            let request = Page.fetchAll()
            request.predicate = NSPredicate(format: "uuid_ == %@", uuid as NSUUID)
            return try? Persistence.shared.context.fetch(request).first
        }
        default: nil
        }
        guard let page else { return }
        sidebar = .all
        DispatchQueue.main.async { withAnimation(Theme.spring) { selectedPage = page } }
    }
}

#if DEBUG
/// CloudKit şemasını Development ortamında eksiksiz oluşturur: her varlığın her alanını dolu bir örnek
/// kayıt gönderilir, senkron bitince silinir. Sonra CloudKit Console'dan "Deploy Schema Changes" yapılır.
///   open "devnote://debug/schema"
@MainActor
enum SchemaSeed {
    static func run() {
        let context = Persistence.shared.context
        let sampleImage = Data(repeating: 0xFF, count: 64)
        let notebook = Notebook.create(name: "Şema örneği", in: context)
        let page = Page.create(title: "Şema örneği", notebook: notebook, in: context)
        let block = page.addBlock(.checklist, text: "Şema örneği", in: context)
        let comment = Comment.add("Şema örneği @kimse", to: block, people: [], in: context)
        for object in [notebook, page, block, comment] as [NSManagedObject] {
            for (name, desc) in object.entity.attributesByName
            where object.value(forKey: name) == nil && !["ckSystemFields_", "parentUUID_", "uuid_"].contains(name) {
                let value: Any? = switch desc.attributeType {
                case .stringAttributeType: "örnek"
                case .dateAttributeType: Date.now
                case .binaryDataAttributeType: sampleImage
                case .UUIDAttributeType: UUID()
                case .booleanAttributeType: false
                case .integer64AttributeType: 0
                case .doubleAttributeType: 0.0
                default: nil
                }
                object.setValue(value, forKey: name)
            }
        }
        Persistence.shared.save()
        print("🧪 şema örneği gönderildi; 20 sn sonra silinecek")
        Task {
            try? await Task.sleep(for: .seconds(20))
            context.delete(notebook)
            Persistence.shared.save()
            print("🧪 şema örneği silindi")
        }
    }
}

/// Simülatörde iCloud ve ikinci kişi olmadan ekip akışını denemek için:
///   xcrun simctl openurl booted devnote://debug/assign      → "Ayşe sana iş atadı" (+ Dynamic Island)
///   xcrun simctl openurl booted devnote://debug/completed   → "Ali görevi tamamladı"
///   xcrun simctl openurl booted devnote://debug/error       → hata uyarısı (uygulama açık kalır)
///   xcrun simctl openurl booted devnote://debug/crash       → çökme; sonraki açılışta rapor gösterilir
@MainActor
enum DemoData {
    static func run(_ action: String) {
        // devnote://debug/error → örnek hata uyarısı, devnote://debug/crash → gerçek çökme (sonraki açılışta rapor)
        if action == "error" {
            ErrorReporter.shared.report(NSError(domain: "DevNote.Demo", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "Deneme hatası: sayfa kaydedilemedi"]), area: "Kaydetme")
            return
        }
        if action == "schema" { SchemaSeed.run(); return }
        if action == "editor" || action == "editor-canvas" { editorDemo(canvas: action == "editor-canvas"); return }
        if action == "blocks" { blocksDemo(); return }
        if action == "crash" {
            let items: [Int] = []
            _ = items[1]
        }
        let persistence = Persistence.shared
        let context = persistence.context
        let notebook = (try? context.fetch(Notebook.fetchAll()))?.first ?? Notebook.create(name: "Ekip", in: context)
        let page = notebook.pages.first { $0.title == "Ekip demo" }
            ?? Page.create(title: "Ekip demo", notebook: notebook, in: context)
        let me = persistence.me
        switch action {
        case "assign":
            let task = page.addBlock(.checklist, text: "Sunum slaytlarını cuma gününe kadar hazırla", in: context)
            task.assigneeID_ = me.id
            task.assigneeName_ = "Ben"
            task.assignedByID_ = "demo-ayse"
            task.assignedByName_ = "Ayşe Yılmaz"
            task.dueDate = .now.addingTimeInterval(45 * 60)
        case "mention":
            // Ayşe bana atadığı göreve yorum yazıp benden bahsediyor → bildirim + etkinlik akışı
            let task = page.addBlock(.checklist, text: "Sprint demosunu hazırla", in: context)
            task.assigneeID_ = me.id
            task.assigneeName_ = "Ben"
            task.assignedByID_ = "demo-ayse"
            task.assignedByName_ = "Ayşe Yılmaz"
            task.assignedAt_ = .now.addingTimeInterval(-600)
            let comment = Comment.add("@Ben demo için son ekranları da ekler misin?", to: task, people: [], in: context)
            comment.authorID_ = "demo-ayse"
            comment.authorName_ = "Ayşe Yılmaz"
            comment.mentionIDs_ = me.id
        case "completed":
            let task = page.addBlock(.checklist, text: "Müşteri geri bildirimlerini topla", in: context)
            task.assigneeID_ = "demo-ali"
            task.assigneeName_ = "Ali Kaya"
            task.assignedByID_ = me.id
            task.assignedByName_ = "Ben"
            task.isDone = true
            task.doneBy = .human
            task.doneAt_ = .now
            task.doneByID_ = "demo-ali"
            task.doneByName_ = "Ali Kaya"
        default:
            return
        }
        persistence.save()
        TaskActions.changed()
    }

    /// Biçimli metin, görsel ve yorumlu görev içeren örnek sayfa; açılıp gösterilir.
    /// Boş belge: Notion tarzı blok düzenlemeyi denemek için
    static func blocksDemo() {
        let context = Persistence.shared.context
        let notebook = (try? context.fetch(Notebook.fetchAll()))?.first ?? Notebook.create(name: "Ekip", in: context)
        let page = Page.create(title: "Blok demo", notebook: notebook, in: context)
        let block = page.addBlock(.text, in: context)
        Persistence.shared.save()
        TaskNotifier.shared.openTaskRequest = block.uuid.uuidString
    }

    static func editorDemo(canvas: Bool = false) {
        let context = Persistence.shared.context
        let notebook = (try? context.fetch(Notebook.fetchAll()))?.first ?? Notebook.create(name: "Ekip", in: context)
        let page = Page.create(title: "Editör demo", notebook: notebook, layout: canvas ? .canvas : .document, in: context)
        page.addBlock(.heading, text: "Sprint planı", in: context)
        page.addBlock(.text, text: "**Kalın**, _italik_, ~~üstü çizili~~, `kod` ve [bağlantı](https://apple.com) desteği.", in: context)
        let task = page.addBlock(.checklist, text: "Tasarım ekranlarını **cuma** gününe kadar bitir", in: context)
        task.assigneeID_ = "demo-ayse"; task.assigneeName_ = "Ayşe Yılmaz"
        task.dueDate = .now.addingTimeInterval(2 * 86_400)
        Comment.add("İlk taslak hazır, bakar mısın?", to: task, people: [], in: context)
        page.addBlock(.checklist, text: "Müşteri toplantısı notlarını paylaş", in: context)
        // Örnek görsel: yumuşak renk geçişi
        let size = 900
        if let ctx = CGContext(data: nil, width: size, height: size * 2 / 3, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let gradient = CGGradient(colorsSpace: nil, colors: [CGColor(red: 0.95, green: 0.71, blue: 0.27, alpha: 1),
                                                                CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)] as CFArray, locations: nil) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size * 2 / 3), options: [])
            if let cg = ctx.makeImage() {
                #if os(iOS)
                let data = UIImage(cgImage: cg).pngData()
                #else
                let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
                #endif
                if let data, let block = ImageImport.add(data, to: page, after: nil, in: context) {
                    block.text = "Ana ekran taslağı"
                }
            }
        }
        Persistence.shared.save()
        TaskNotifier.shared.openTaskRequest = task.uuid.uuidString
    }
}
#endif
