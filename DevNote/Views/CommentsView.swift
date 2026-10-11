import SwiftUI
import CoreData

/// Bir bloğun (genelde görevin) yorumları. "@isim" ile ekip arkadaşından bahsedilir; bahsedilene bildirim gider.
struct CommentsSheet: View {
    @ObservedObject var block: Block
    @Environment(\.participants) private var participants
    @Environment(\.canEditPage) private var canEdit
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var accent: Color { block.page?.notebook?.color ?? .accentColor }

    /// Yazılan son kelime "@..." ise bahsetme önerisi göster
    private var mentionQuery: String? {
        guard let last = draft.split(separator: " ", omittingEmptySubsequences: false).last,
              last.hasPrefix("@") else { return nil }
        return String(last.dropFirst())
    }

    private var suggestions: [Person] {
        guard let query = mentionQuery else { return [] }
        return participants.filter { !$0.isMe && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section { header }
                    if block.comments.isEmpty {
                        Text("Henüz yorum yok. Soru sor, durum bildir ya da @ ile birinden bahset.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(block.comments) { comment in
                        CommentRow(comment: comment, participants: participants, accent: accent)
                            .id(comment.uuid)
                            .contextMenu {
                                if comment.isMine {
                                    Button("Sil", systemImage: "trash", role: .destructive) { delete(comment) }
                                }
                            }
                            .swipeActions {
                                if comment.isMine {
                                    Button("Sil", systemImage: "trash", role: .destructive) { delete(comment) }
                                }
                            }
                    }
                }
                .onAppear { proxy.scrollTo(block.comments.last?.uuid, anchor: .bottom) }
                .onChange(of: block.comments.count) {
                    withAnimation(Theme.spring) { proxy.scrollTo(block.comments.last?.uuid, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom) { if canEdit { inputBar } }
            .navigationTitle("Yorumlar")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if block.kind == .checklist {
                    Image(systemName: block.isDone ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(block.isDone ? accent : .secondary)
                }
                Text(InlineFormat.rendered(block.text.isEmpty ? "Başlıksız" : block.text))
                    .font(.headline)
                    .strikethrough(block.isDone)
            }
            HStack(spacing: 10) {
                if let name = block.assigneeName {
                    Label(block.isAssignedToMe ? "Sana atandı" : name, systemImage: "person.fill")
                }
                if let due = block.dueDate {
                    Label(due.formatted(.relative(presentation: .named)), systemImage: "bell.fill")
                        .foregroundStyle(due < .now && !block.isDone ? .red : .orange)
                }
                if let page = block.page { Label(page.title.isEmpty ? "Başlıksız" : page.title, systemImage: "doc.text") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(suggestions) { person in
                            Button { insertMention(person) } label: {
                                HStack(spacing: 6) {
                                    Avatar(name: person.name, tint: accent).scaleEffect(0.7).frame(width: 22, height: 22)
                                    Text(person.name)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.thinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(participants.count > 1 ? "Yorum yaz… (@ ile birinden bahset)" : "Yorum yaz…",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 10)
        .background(.bar)
        .animation(Theme.spring, value: suggestions.map(\.id))
    }

    private func insertMention(_ person: Person) {
        var words = draft.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if !words.isEmpty { words.removeLast() }
        words.append("@\(person.name) ")
        draft = words.joined(separator: " ")
        inputFocused = true
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation(Theme.spring) {
            Comment.add(text, to: block, people: participants, in: context)
        }
        draft = ""
        Persistence.shared.save()
        TaskActions.changed()
    }

    private func delete(_ comment: Comment) {
        withAnimation(Theme.spring) { context.delete(comment) }
        Persistence.shared.save()
    }
}

struct CommentRow: View {
    @ObservedObject var comment: Comment
    let participants: [Person]
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: comment.authorName, tint: comment.isMine ? accent : .gray)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comment.isMine && !comment.authorName.hasPrefix("Yapay zeka") ? "Sen" : comment.authorName)
                        .font(.subheadline.weight(.semibold))
                    Text(comment.createdAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(highlighted)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    /// Markdown + bahsedilen isimler vurgulu
    private var highlighted: AttributedString {
        var text = InlineFormat.rendered(comment.text)
        for person in participants {
            var searchRange = text.startIndex..<text.endIndex
            while let range = text[searchRange].range(of: "@\(person.name)", options: .caseInsensitive) {
                text[range].foregroundColor = accent
                text[range].font = .callout.weight(.semibold)
                searchRange = range.upperBound..<text.endIndex
            }
        }
        return text
    }
}
