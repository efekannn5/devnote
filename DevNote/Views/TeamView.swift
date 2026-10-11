import SwiftUI
import CloudKit
import CoreData

/// Paylaşılan defterin ekibi: kişiler, rolleri, yetkileri ve her birine atanmış açık görevler.
struct TeamView: View {
    @ObservedObject var notebook: Notebook
    @EnvironmentObject private var persistence: Persistence
    @ObservedObject private var cloud = CloudSync.shared
    @Environment(\.dismiss) private var dismiss
    @State private var refreshing = false
    @State private var showAllEvents = false

    private var members: [TeamMember] { persistence.teamMembers(for: notebook) }

    private var openTasks: [Block] {
        notebook.pages.flatMap(\.tasks).filter { !$0.isDone }
    }

    var body: some View {
        NavigationStack {
            List {
                if !persistence.isShared(notebook) {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Bu defter henüz paylaşılmadı", systemImage: "person.2.slash")
                                .font(.headline)
                            Text("Ekip arkadaşlarını iCloud ile davet et. Katıldıktan sonra notları birlikte düzenleyebilir, birbirinize görev atayabilirsiniz.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section {
                    ForEach(members) { member in
                        MemberRow(member: member,
                                  tasks: openTasks.filter { $0.assigneeID == member.person.id },
                                  accent: notebook.color)
                    }
                    if persistence.isSharedWithMe(notebook) == false {
                        ShareLink(item: NotebookShareItem(notebook: notebook),
                                  preview: SharePreview(notebook.name, image: Image(systemName: notebook.icon))) {
                            Label(persistence.isShared(notebook) ? "Kişi ekle / paylaşımı yönet" : "Ekip arkadaşı davet et",
                                  systemImage: "person.crop.circle.badge.plus")
                        }
                    }
                } header: {
                    Text(members.isEmpty ? "" : "\(members.count) kişi")
                }

                let events = ActivityEvent.recent(in: notebook)
                if !events.isEmpty {
                    Section("Son etkinlikler") {
                        ForEach(events.prefix(showAllEvents ? 60 : 8)) { event in
                            Button {
                                guard let taskID = event.taskID else { return }
                                dismiss()
                                TaskNotifier.shared.openTaskRequest = taskID
                            } label: {
                                ActivityRow(event: event, accent: notebook.color)
                            }
                            .buttonStyle(.plain)
                        }
                        if events.count > 8 && !showAllEvents {
                            Button("Tümünü göster (\(min(events.count, 60)))") {
                                withAnimation(Theme.spring) { showAllEvents = true }
                            }
                        }
                    }
                }

                let unassigned = openTasks.filter { $0.assigneeID == nil }
                if !unassigned.isEmpty && persistence.isShared(notebook) {
                    Section("Atanmamış görevler") {
                        ForEach(unassigned) { task in
                            AssignableTaskRow(task: task, members: members.filter(\.accepted).map(\.person))
                        }
                    }
                }
            }
            .navigationTitle(notebook.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { dismiss() }
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task {
                            refreshing = true
                            await cloud.refreshShare(for: notebook)
                            refreshing = false
                        }
                    } label: {
                        Label("Yenile", systemImage: "arrow.clockwise")
                            .symbolEffect(.rotate, isActive: refreshing)
                    }
                }
            }
            .task { await cloud.refreshShare(for: notebook) }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}

/// Defterde son 14 günde olanlar; kayıtlardaki zaman / kişi alanlarından türetilir (ayrıca saklanmaz).
struct ActivityEvent: Identifiable {
    enum Kind { case page, assigned, done, comment }
    let id: String
    let kind: Kind
    let date: Date
    let actor: String
    let text: String
    let detail: String
    let taskID: String?

    var symbol: String {
        switch kind {
        case .page: "doc.badge.plus"
        case .assigned: "person.crop.circle.badge.plus"
        case .done: "checkmark.circle.fill"
        case .comment: "bubble.left.fill"
        }
    }

    @MainActor
    static func recent(in notebook: Notebook, days: Int = 14) -> [ActivityEvent] {
        let since = Date.now.addingTimeInterval(-Double(days) * 86_400)
        let myID = Persistence.shared.me.id
        let myName = Persistence.shared.myDisplayName(for: notebook)
        let shared = Persistence.shared.isShared(notebook)
        /// Ben miyim? (kimlik ya da paylaşımdaki adım; paylaşılmamış defterde her şey benim)
        func isMe(_ name: String?, id: String? = nil) -> Bool {
            if let id { return id == myID }
            return !shared || name == nil || name == myName
        }
        /// "Sen …dın" / "Ayşe …dı"
        func phrase(_ me: Bool, _ name: String?, _ mine: String, _ theirs: String) -> (String, String) {
            me ? ("Sen", mine) : (name ?? "Biri", theirs)
        }
        func short(_ text: String) -> String {
            let plain = String(InlineFormat.rendered(text).characters)
            return plain.isEmpty ? "Başlıksız" : String(plain.prefix(80))
        }
        var events: [ActivityEvent] = []
        for page in notebook.pages {
            if let date = page.createdAt_, date > since {
                let (actor, text) = phrase(isMe(page.authorName_), page.authorName_, "sayfa oluşturdun", "sayfa oluşturdu")
                events.append(.init(id: "page-\(page.uuid)", kind: .page, date: date, actor: actor,
                                    text: text, detail: short(page.title), taskID: nil))
            }
            for block in page.sortedBlocks where block.kind == .checklist || !block.comments.isEmpty {
                let task = block.uuid.uuidString
                if let date = block.assignedAt_, date > since, let assignee = block.assigneeName {
                    let to = block.assigneeID == block.assignedByID ? "kendine" : block.assigneeID == myID ? "sana" : "\(assignee) kişisine"
                    let (actor, text) = phrase(isMe(block.assignedByName, id: block.assignedByID), block.assignedByName,
                                               "\(to) görev atadın", "\(to) görev atadı")
                    events.append(.init(id: "assign-\(task)", kind: .assigned, date: date, actor: actor,
                                        text: text, detail: short(block.text), taskID: task))
                }
                if block.isDone, let date = block.doneAt_, date > since {
                    let (actor, text) = phrase(isMe(block.doneByName, id: block.doneByID_), block.doneByName,
                                               "görevi tamamladın", "görevi tamamladı")
                    events.append(.init(id: "done-\(task)", kind: .done, date: date, actor: actor,
                                        text: block.doneBy == .ai ? "görevi yapay zeka ile tamamladı" : text,
                                        detail: short(block.text), taskID: task))
                }
                for comment in block.comments where comment.createdAt > since {
                    let quote = "„\(short(comment.text))“"
                    let (actor, text) = phrase(comment.isMine && !comment.authorName.hasPrefix("Yapay zeka"), comment.authorName,
                                               "yorum yaptın: \(quote)", "yorum yaptı: \(quote)")
                    events.append(.init(id: "comment-\(comment.uuid)", kind: .comment, date: comment.createdAt,
                                        actor: actor, text: text, detail: short(block.text), taskID: task))
                }
            }
        }
        return events.sorted { $0.date > $1.date }
    }
}

struct ActivityRow: View {
    let event: ActivityEvent
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.symbol)
                .foregroundStyle(event.kind == .done ? .green : accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                (Text(event.actor).fontWeight(.semibold) + Text(" \(event.text)"))
                    .font(.callout)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(event.detail).lineLimit(1)
                    Text("·")
                    Text(event.date, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

struct MemberRow: View {
    let member: TeamMember
    let tasks: [Block]
    let accent: Color
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if tasks.isEmpty {
                Text("Açık görevi yok").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(tasks) { task in
                    HStack {
                        Image(systemName: "circle").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(task.text).lineLimit(2)
                            if let due = task.dueDate {
                                Text(due, format: .relative(presentation: .named))
                                    .font(.caption)
                                    .foregroundStyle(due < .now ? .red : .orange)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Avatar(name: member.person.name, tint: member.person.isMe ? accent : .gray)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(member.person.isMe ? "Sen" : member.person.name).font(.body.weight(.medium))
                        if member.isOwner {
                            Text("Sahip")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(accent.opacity(0.15), in: Capsule())
                                .foregroundStyle(accent)
                        }
                    }
                    HStack(spacing: 6) {
                        Label(member.canEdit ? "Düzenleyebilir" : "Görüntüleyebilir",
                              systemImage: member.canEdit ? "pencil" : "eye")
                        if !member.accepted {
                            Label("Davet bekliyor", systemImage: "hourglass").foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if !tasks.isEmpty {
                    Text("\(tasks.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }
}

struct AssignableTaskRow: View {
    @ObservedObject var task: Block
    let members: [Person]

    var body: some View {
        HStack {
            Text(task.text).lineLimit(2)
            Spacer()
            Menu {
                ForEach(members.filter { !$0.id.isEmpty }) { person in
                    Button(person.isMe ? "Bana ata" : person.name) {
                        withAnimation(Theme.spring) { task.assign(to: person) }
                        TaskActions.changed()
                    }
                }
            } label: {
                Label("Ata", systemImage: "person.crop.circle.badge.plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

struct Avatar: View {
    let name: String
    let tint: Color

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        Text(initials.isEmpty ? "?" : initials)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(tint.gradient, in: Circle())
    }
}

struct TeamMember: Identifiable {
    var person: Person
    var isOwner: Bool
    var canEdit: Bool
    var accepted: Bool
    var id: String { person.id }
}

extension Persistence {
    /// Davet bekleyenler dahil tüm katılımcılar.
    func teamMembers(for notebook: Notebook) -> [TeamMember] {
        guard let share = existingShare(for: notebook) else {
            // Paylaşılmamış: yalnızca ben
            return [TeamMember(person: me, isOwner: true, canEdit: true, accepted: true)]
        }
        return share.participants.compactMap { participant -> TeamMember? in
            let isMe = participant == share.currentUserParticipant
            let id = isMe ? me.id : (participant.userIdentity.userRecordID?.recordName
                                     ?? participant.userIdentity.lookupInfo?.emailAddress ?? "")
            guard !id.isEmpty else { return nil }
            return TeamMember(person: Person(id: id, name: isMe ? "Ben" : Self.displayName(of: participant), isMe: isMe),
                              isOwner: participant.role == .owner,
                              canEdit: participant.permission == .readWrite,
                              accepted: participant.acceptanceStatus == .accepted)
        }
        .sorted { ($0.isOwner ? 0 : 1, $0.person.isMe ? 0 : 1, $0.person.name) < ($1.isOwner ? 0 : 1, $1.person.isMe ? 0 : 1, $1.person.name) }
    }
}
