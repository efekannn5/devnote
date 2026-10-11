import Foundation
import CoreData
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Açık görevlerin özetini widget'ın okuyacağı App Group dosyasına yazar.
@MainActor
enum WidgetSync {
    static func update() {
        #if os(iOS)
        let persistence = Persistence.shared
        let myID = persistence.me.id
        let context = persistence.context
        let open = (try? context.fetch(Block.fetchAll(predicate: NSPredicate(
            format: "kind_ == %@ AND isDone == NO", BlockKind.checklist.rawValue)))) ?? []
        // Başkasına atanmış işler benim listemde değil
        let mine = open.filter { $0.assigneeID == nil || $0.assigneeID == myID }
            .sorted { a, b in
                switch (a.dueDate, b.dueDate) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    if a.isAssignedToMe != b.isAssignedToMe { return a.isAssignedToMe }
                    return (a.page?.updatedAt ?? .distantPast) > (b.page?.updatedAt ?? .distantPast)
                }
            }
        let startOfDay = Calendar.current.startOfDay(for: .now)
        let doneToday = (try? context.count(for: Block.fetchAll(predicate: NSPredicate(
            format: "kind_ == %@ AND isDone == YES AND doneAt_ >= %@", BlockKind.checklist.rawValue, startOfDay as NSDate)))) ?? 0

        let snapshot = WidgetSnapshot(
            tasks: mine.prefix(20).map { block in
                .init(id: block.uuid.uuidString,
                      title: String(InlineFormat.rendered(block.text).characters).nilIfEmpty ?? "Başlıksız görev",
                      page: block.page?.title.nilIfEmpty ?? "Başlıksız",
                      notebook: block.page?.notebook?.name ?? "",
                      colorHex: block.page?.notebook?.colorHex ?? "#0A84FF",
                      due: block.dueDate,
                      assignedBy: block.isAssignedToMe && block.assignedByID != myID ? block.assignedByName : nil,
                      isAssignedToMe: block.isAssignedToMe)
            },
            openCount: mine.count, doneToday: doneToday, updatedAt: .now)
        if snapshot.save() {
            WidgetCenter.shared.reloadTimelines(ofKind: "DevNoteTasks")
        }
        #endif
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
