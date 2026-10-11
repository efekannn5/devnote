import AppIntents
import CoreData

/// Siri / Kestirmeler / Spotlight: "DevNote'a görev ekle", "DevNote'ta açık görevlerim"
struct AddTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Görev ekle"
    static var description = IntentDescription("DevNote'taki Hızlı görevler sayfasına yeni bir yapılacak ekler.")

    @Parameter(title: "Görev", requestValueDialog: "Ne yapılacak?")
    var text: String

    static var parameterSummary: some ParameterSummary { Summary("\(\.$text) görevini ekle") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .result(dialog: "Boş görev eklenmedi.") }
        let persistence = Persistence.shared
        let context = persistence.context
        let notebooks = (try? context.fetch(Notebook.fetchAll())) ?? []
        // Paylaşılmamış ilk deftere: kişisel hızlı not başkalarının önüne düşmesin
        let notebook = notebooks.first { !persistence.isShared($0) } ?? notebooks.first
            ?? Notebook.create(name: "Kişisel", in: context)
        let page = notebook.pages.first { $0.title == Self.inboxTitle }
            ?? Page.create(title: Self.inboxTitle, notebook: notebook, in: context)
        page.addBlock(.checklist, text: trimmed, in: context)
        persistence.save()
        TaskActions.changed()
        WidgetSync.update()
        return .result(dialog: "Eklendi: \(trimmed)")
    }

    static let inboxTitle = "Hızlı görevler"
}

struct OpenTasksIntent: AppIntent {
    static var title: LocalizedStringResource = "Açık görevlerim"
    static var description = IntentDescription("Sana atanmış ya da kimseye atanmamış açık görevleri söyler.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        WidgetSync.update()
        let tasks = WidgetSnapshot.load().tasks
        guard !tasks.isEmpty else { return .result(dialog: "Açık görevin yok. 🎉") }
        let list = tasks.prefix(5).map { "• \($0.title)" }.joined(separator: "\n")
        let more = tasks.count > 5 ? "\nve \(tasks.count - 5) görev daha." : ""
        return .result(dialog: "\(tasks.count) açık görevin var:\n\(list)\(more)")
    }
}

struct DevNoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddTaskIntent(),
                    phrases: ["\(.applicationName)'a görev ekle", "\(.applicationName) ile görev ekle",
                              "Add a task in \(.applicationName)"],
                    shortTitle: "Görev ekle", systemImageName: "plus.circle")
        AppShortcut(intent: OpenTasksIntent(),
                    phrases: ["\(.applicationName)'ta açık görevlerim", "\(.applicationName) görevlerim",
                              "My tasks in \(.applicationName)"],
                    shortTitle: "Açık görevlerim", systemImageName: "checklist")
    }
}
