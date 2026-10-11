import SwiftUI
import CoreData

struct PageListView: View {
    var filter: SidebarItem
    var search: String
    @Binding var selection: Page?

    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var persistence: Persistence
    @FetchRequest(fetchRequest: Page.fetchAll()) private var allPages: FetchedResults<Page>
    @FetchRequest(fetchRequest: Notebook.fetchAll()) private var notebooks: FetchedResults<Notebook>

    private var pages: [Page] {
        let all = Array(allPages)
        let base: [Page] = switch filter {
        case .all: all
        case .pinned: all.filter(\.isPinned)
        case .openTasks: all.filter { $0.openTaskCount > 0 }
        case .assignedToMe: all.filter { $0.tasks.contains { !$0.isDone && $0.assigneeID == persistence.me.id } }
        case .aiCompleted: all.filter(\.hasAICompletions)
        case .notebook(let nb): all.filter { $0.notebook == nb }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? base : base.filter { page in
            page.title.localizedCaseInsensitiveContains(q)
                || page.sortedBlocks.contains { $0.text.localizedCaseInsensitiveContains(q) }
        }
        // Sabitlenenler her zaman üstte
        return filtered.filter(\.isPinned) + filtered.filter { !$0.isPinned }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(pages) { page in
                PageRow(page: page)
                    .tag(page)
                    .contextMenu { menu(for: page) }
                    .swipeActions(edge: .trailing) {
                        Button("Sil", systemImage: "trash", role: .destructive) { delete(page) }
                    }
                    .swipeActions(edge: .leading) {
                        Button(page.isPinned ? "Kaldır" : "Sabitle", systemImage: "pin") {
                            withAnimation(Theme.spring) { page.isPinned.toggle() }
                        }
                        .tint(.orange)
                    }
            }
        }
        .animation(Theme.spring, value: pages.map(\.uuid))
        .overlay {
            if pages.isEmpty {
                ContentUnavailableView(search.isEmpty ? "Henüz not yok" : "Sonuç yok",
                                       systemImage: search.isEmpty ? "square.and.pencil" : "magnifyingglass")
            }
        }
        .navigationTitle(filter.title)
        .toolbar {
            ToolbarItemGroup {
                // Görünüm not oluşturulurken seçilir (sonradan değişmez, içerik karışmasın)
                Menu {
                    Section("Yeni not nasıl olsun?") {
                        Button { newPage(.document) } label: {
                            Label("Belge — Notion gibi bloklar", systemImage: PageLayout.document.symbol)
                        }
                        Button { newPage(.canvas) } label: {
                            Label("Tuval — serbest kutular ve çizim", systemImage: PageLayout.canvas.symbol)
                        }
                    }
                } label: {
                    Label("Yeni Not", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("new-note")
            }
        }
        .background {
            // Kısayollar: ⌘N belge, ⇧⌘N tuval
            Group {
                Button("Yeni Belge") { newPage(.document) }.keyboardShortcut("n", modifiers: .command)
                Button("Yeni Tuval") { newPage(.canvas) }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func menu(for page: Page) -> some View {
        Button(page.isPinned ? "Sabitlemeyi Kaldır" : "Sabitle", systemImage: "pin") {
            withAnimation(Theme.spring) { page.isPinned.toggle() }
        }
        // Sadece aynı sahibin defterlerine taşı (başkasının paylaştığı deftere taşıma yok)
        let movable = notebooks.filter { $0.zoneOwner_ == page.zoneOwner_ && $0 != page.notebook }
        if !movable.isEmpty && persistence.canEdit(page) {
            Menu("Deftere Taşı", systemImage: "folder") {
                ForEach(movable) { nb in
                    Button(nb.name) { withAnimation(Theme.spring) { page.move(to: nb) } }
                }
            }
        }
        Divider()
        Button("Sil", systemImage: "trash", role: .destructive) { delete(page) }
    }

    private func newPage(_ layout: PageLayout) {
        var nb: Notebook? = if case .notebook(let nb) = filter { nb } else { notebooks.first { !persistence.isSharedWithMe($0) } }
        if nb == nil { nb = Notebook.create(name: "Notlar", in: context) }
        let page = Page.create(title: "", notebook: nb, layout: layout, in: context)
        if layout == .document { page.addBlock(.text, in: context) }
        withAnimation(Theme.spring) { selection = page }
    }

    private func delete(_ page: Page) {
        if selection == page { selection = nil }
        withAnimation(Theme.spring) { context.delete(page) }
        persistence.save()
    }
}

struct PageRow: View {
    @ObservedObject var page: Page
    @EnvironmentObject private var persistence: Persistence

    var body: some View {
        if page.isDeleted || page.managedObjectContext == nil {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if page.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                }
                Text(page.title.isEmpty ? "Başlıksız" : page.title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(page.title.isEmpty ? .secondary : .primary)
                Spacer(minLength: 4)
                if page.layout == .canvas {
                    Image(systemName: PageLayout.canvas.symbol).font(.caption).foregroundStyle(.secondary)
                }
                if !page.tasks.isEmpty {
                    ProgressRing(progress: page.progress, tint: page.notebook?.color ?? .accentColor, size: 14)
                }
            }
            Text(page.snippet.isEmpty ? "Ek metin yok" : page.snippet)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                if let nb = page.notebook {
                    Circle().fill(nb.color).frame(width: 6, height: 6)
                    Text(nb.name)
                    if persistence.isShared(nb) {
                        Image(systemName: "person.2.fill")
                    }
                }
                Text(page.updatedAt, format: .relative(presentation: .named))
                if page.hasAICompletions {
                    Image(systemName: "sparkles").foregroundStyle(Theme.aiTint)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
