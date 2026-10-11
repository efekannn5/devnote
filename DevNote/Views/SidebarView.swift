import SwiftUI
import CoreData

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var persistence: Persistence
    @ObservedObject private var peers = PeerSync.shared
    @ObservedObject private var cloud = CloudSync.shared
    @ObservedObject private var errors = ErrorReporter.shared
    @State private var showingErrors = false
    @FetchRequest(fetchRequest: Notebook.fetchAll()) private var notebooks: FetchedResults<Notebook>
    @FetchRequest(fetchRequest: Page.fetchAll()) private var pages: FetchedResults<Page>

    @State private var editing: Notebook?
    @State private var creating = false

    #if os(macOS)
    @EnvironmentObject private var mcp: MCPServer
    #endif

    private var myNotebooks: [Notebook] { notebooks.filter { !persistence.isSharedWithMe($0) } }
    private var sharedWithMe: [Notebook] { notebooks.filter { persistence.isSharedWithMe($0) } }

    private var assignedToMeCount: Int {
        pages.reduce(0) { sum, page in
            sum + page.tasks.filter { !$0.isDone && $0.assigneeID == persistence.me.id }.count
        }
    }

    var body: some View {
        List(selection: $selection) {
            Section("Akıllı Listeler") {
                smartRow(.all, symbol: "tray.full.fill", tint: .gray, count: pages.count)
                smartRow(.pinned, symbol: "pin.fill", tint: .orange, count: pages.filter(\.isPinned).count)
                smartRow(.openTasks, symbol: "checklist", tint: .blue,
                         count: pages.reduce(0) { $0 + $1.openTaskCount })
                if Persistence.cloudEnabled {
                    smartRow(.assignedToMe, symbol: "person.crop.circle.badge.checkmark", tint: .green,
                             count: assignedToMeCount)
                }
                smartRow(.aiCompleted, symbol: "sparkles", tint: Theme.aiTint,
                         count: pages.filter(\.hasAICompletions).count)
            }

            Section("Defterlerim") {
                ForEach(myNotebooks) { nb in notebookRow(nb) }
                    .onMove(perform: move)
            }

            if !sharedWithMe.isEmpty {
                Section("Benimle Paylaşılanlar") {
                    ForEach(sharedWithMe) { nb in notebookRow(nb) }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("DevNote")
        .toolbar {
            ToolbarItem {
                Button("Yeni Defter", systemImage: "folder.badge.plus") { creating = true }
            }
        }
        .sheet(isPresented: $creating) {
            NotebookEditor(notebook: nil)
        }
        .sheet(item: $editing) { nb in
            NotebookEditor(notebook: nb)
        }
        .safeAreaInset(edge: .bottom) { statusBar }
        .sheet(isPresented: $showingErrors) { ErrorLogView() }
    }

    private func notebookRow(_ nb: Notebook) -> some View {
        Label {
            HStack {
                Text(nb.name)
                if persistence.isShared(nb) {
                    Image(systemName: "person.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(nb.pages.count)").foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: {
            Image(systemName: nb.icon).foregroundStyle(nb.color)
        }
        .tag(SidebarItem.notebook(nb))
        .contextMenu {
            if Persistence.cloudEnabled {
                ShareLink(item: NotebookShareItem(notebook: nb),
                          preview: SharePreview(nb.name, image: Image(systemName: nb.icon))) {
                    Label(persistence.isShared(nb) ? "Paylaşımı Yönet…" : "Paylaş…",
                          systemImage: "person.crop.circle.badge.plus")
                }
                Divider()
            }
            if persistence.canEdit(nb) {
                Button("Düzenle…", systemImage: "pencil") { editing = nb }
            }
            Divider()
            Button(persistence.isSharedWithMe(nb) ? "Paylaşımdan Ayrıl" : "Sil",
                   systemImage: "trash", role: .destructive) { delete(nb) }
        }
    }

    private func smartRow(_ item: SidebarItem, symbol: String, tint: Color, count: Int) -> some View {
        Label {
            HStack {
                Text(item.title)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .tag(item)
    }

    private func delete(_ nb: Notebook) {
        if selection == .notebook(nb) { selection = .all }
        withAnimation(Theme.spring) { context.delete(nb) }
        persistence.save()
    }

    private func move(from: IndexSet, to: Int) {
        var list = myNotebooks
        list.move(fromOffsets: from, toOffset: to)
        for (i, nb) in list.enumerated() { nb.sortIndex = Int64(i) }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if os(macOS)
            HStack(spacing: 8) {
                Circle()
                    .fill(mcp.isRunning ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                    .shadow(color: mcp.isRunning ? .green : .clear, radius: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mcp.isRunning ? "MCP · localhost:\(String(mcp.port))" : "MCP kapalı")
                        .font(.caption.weight(.medium))
                    if let last = mcp.lastActivity {
                        Text(last).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            #endif
            if !peers.connectedNames.isEmpty {
                Label("Anlık: \(peers.connectedNames.joined(separator: ", "))", systemImage: "bolt.horizontal.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            HStack {
                Label(cloud.status,
                      systemImage: Persistence.cloudEnabled ? "icloud" : "internaldrive")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button { showingErrors = true } label: {
                    if errors.recent.isEmpty {
                        Image(systemName: "doc.text.magnifyingglass")
                    } else {
                        Label("\(errors.recent.count)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Hata kayıtları")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .animation(Theme.spring, value: peers.connectedNames)
        #if os(macOS)
        .animation(Theme.spring, value: mcp.lastActivity)
        #endif
    }
}

struct NotebookEditor: View {
    var notebook: Notebook?
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var persistence: Persistence
    @FetchRequest(fetchRequest: Notebook.fetchAll()) private var notebooks: FetchedResults<Notebook>

    @State private var name = ""
    @State private var icon = Theme.icons[0]
    @State private var colorHex = Theme.palette[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Color(hex: colorHex).gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                TextField("Defter adı", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
            }

            HStack(spacing: 10) {
                ForEach(Theme.palette, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.primary.opacity(hex == colorHex ? 0.6 : 0), lineWidth: 2).padding(-3))
                        .onTapGesture { withAnimation(Theme.spring) { colorHex = hex } }
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 7), spacing: 8) {
                ForEach(Theme.icons, id: \.self) { sym in
                    Image(systemName: sym)
                        .frame(width: 34, height: 34)
                        .background(sym == icon ? Color(hex: colorHex).opacity(0.2) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(sym == icon ? Color(hex: colorHex) : .secondary)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(Theme.spring) { icon = sym } }
                }
            }

            HStack {
                Spacer()
                Button("Vazgeç", role: .cancel) { dismiss() }
                Button(notebook == nil ? "Oluştur" : "Kaydet") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 360)
        .onAppear {
            if let notebook {
                name = notebook.name; icon = notebook.icon; colorHex = notebook.colorHex
            }
        }
    }

    private func save() {
        if let notebook {
            notebook.name = name; notebook.icon = icon; notebook.colorHex = colorHex
        } else {
            Notebook.create(name: name, icon: icon, colorHex: colorHex, sortIndex: notebooks.count, in: context)
        }
        persistence.save()
        dismiss()
    }
}
