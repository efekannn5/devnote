import Foundation
import CoreData
#if os(iOS)
import ActivityKit
#endif

/// Uygulamanın her yerinden (Dynamic Island butonu, bildirim butonu, MCP, arayüz) kullanılan
/// görev işlemleri.
@MainActor
enum TaskActions {
    static func block(_ uuidString: String) -> Block? {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        let request = Block.fetchAll(predicate: NSPredicate(format: "uuid_ == %@", uuid as NSUUID))
        request.fetchLimit = 1
        return try? Persistence.shared.context.fetch(request).first
    }

    static func complete(_ uuidString: String) {
        guard let block = block(uuidString), !block.isDone else { return }
        block.setDone(true, by: .human)
        Persistence.shared.save()
        // Widget'tan gelindiyse uygulama hemen arka plana döner; özeti beklemeden yaz
        WidgetSync.update()
        changed()
    }

    /// Bir görev değiştiğinde bildirimleri ve Dynamic Island'ı güncelle.
    static func changed() {
        TaskNotifier.shared.scheduleRefresh()
        #if os(iOS)
        LiveActivities.shared.refresh()
        #endif
    }

    static func install() {
        #if os(iOS)
        TaskIntentBridge.complete = { id in
            await MainActor.run { TaskActions.complete(id) }
        }
        #endif
    }
}

#if os(iOS)
/// Dynamic Island / kilit ekranı görevleri.
@MainActor
final class LiveActivities {
    static let shared = LiveActivities()

    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func isTracking(_ block: Block) -> Bool {
        Activity<TaskActivityAttributes>.activities.contains { $0.attributes.taskID == block.uuid.uuidString }
    }

    /// Görevi Dynamic Island'da göster (zaten varsa güncelle).
    func start(_ block: Block) {
        guard isEnabled, block.kind == .checklist else { return }
        let id = block.uuid.uuidString
        if let existing = Activity<TaskActivityAttributes>.activities.first(where: { $0.attributes.taskID == id }) {
            Task { await existing.update(content(for: block)) }
            return
        }
        let notebook = block.page?.notebook
        let attributes = TaskActivityAttributes(taskID: id,
                                                notebookName: notebook?.name ?? "DevNote",
                                                notebookIcon: notebook?.icon ?? "checklist",
                                                accentHex: notebook?.colorHex ?? "#0A84FF")
        do {
            _ = try Activity.request(attributes: attributes, content: content(for: block), pushType: nil)
        } catch {
            ErrorReporter.shared.report(error, area: "Dynamic Island", silent: true)
        }
    }

    func stop(_ block: Block) {
        let id = block.uuid.uuidString
        for activity in Activity<TaskActivityAttributes>.activities where activity.attributes.taskID == id {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Açık etkinlikleri görevlerin güncel durumuna getir; biten görevi kısa süre "Tamamlandı" göster.
    func refresh() {
        for activity in Activity<TaskActivityAttributes>.activities {
            guard let block = TaskActions.block(activity.attributes.taskID) else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                continue
            }
            let content = content(for: block)
            if block.isDone {
                Task { await activity.end(content, dismissalPolicy: .after(.now + 8)) }
            } else if content.state != activity.content.state {
                Task { await activity.update(content) }
            }
        }
    }

    private func content(for block: Block) -> ActivityContent<TaskActivityAttributes.ContentState> {
        let tasks = block.page?.tasks ?? [block]
        let state = TaskActivityAttributes.ContentState(
            title: block.text,
            pageTitle: block.page?.title.isEmpty == false ? block.page!.title : "Başlıksız",
            assignedBy: block.isAssignedToMe && block.assignedByID != Persistence.shared.me.id ? block.assignedByName : nil,
            dueDate: block.dueDate,
            isDone: block.isDone,
            doneCount: tasks.filter(\.isDone).count,
            totalCount: tasks.count)
        // Son tarihten 1 saat sonra "eski" say (sistem soluklaştırır)
        return ActivityContent(state: state, staleDate: block.dueDate.map { $0.addingTimeInterval(3600) })
    }
}
#endif
