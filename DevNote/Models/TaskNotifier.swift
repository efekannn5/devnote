import Foundation
import CoreData
import UserNotifications

/// Görev bildirimleri:
///  - Bana yeni bir iş atandı → zamana duyarlı bildirim (+ iPhone'da Dynamic Island)
///  - Atadığım bir işi başkası tamamladı → bildirim
///  - Benden bahseden ya da benim görevime / atadığım göreve yazılan yorum → bildirim
///  - Son tarihi gelen görev → hatırlatma
/// Bildirimlerde "Tamamla" ve "Aç" düğmeleri var. Buluttan / yakın cihazdan her değişiklikte yeniden hesaplanır.
@MainActor
final class TaskNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TaskNotifier()

    static let taskCategory = "TASK"
    static let completeAction = "COMPLETE"

    private let center = UNUserNotificationCenter.current()
    private var pending: Task<Void, Never>?
    private let notifiedKey = "notifiedTaskEvents"
    private let primedKey = "notifierPrimed-v2"
    /// İlk çalışmada eski yorumlar için bildirim yağmasın
    private let commentsPrimedKey = "notifierPrimed-comments"

    /// Dokunulan bildirimin açması gereken görev (RootView dinler)
    @Published var openTaskRequest: String?

    func start() {
        center.delegate = self
        let complete = UNNotificationAction(identifier: Self.completeAction, title: "Tamamla",
                                            options: [.authenticationRequired],
                                            icon: UNNotificationActionIcon(systemImageName: "checkmark.circle"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.taskCategory, actions: [complete], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        scheduleRefresh()
    }

    /// Birden çok değişikliği tek bir hesaplamada topla.
    func scheduleRefresh() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func refresh() async {
        let persistence = Persistence.shared
        let myID = persistence.me.id
        let context = persistence.context
        var notified = Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? [])
        let primed = UserDefaults.standard.bool(forKey: primedKey)

        // 1) Bana atanan yeni işler
        let assigned = (try? context.fetch(Block.fetchAll(predicate: NSPredicate(
            format: "kind_ == %@ AND isDone == NO AND assigneeID_ == %@", BlockKind.checklist.rawValue, myID)))) ?? []
        for block in assigned {
            let key = "assign-\(block.uuid)-\(myID)"
            guard notified.insert(key).inserted, primed, block.assignedByID != myID else { continue }
            await post(id: key, block: block,
                       title: "\(block.assignedByName ?? "Bir ekip üyesi") sana bir iş atadı",
                       timeSensitive: true)
            #if os(iOS)
            LiveActivities.shared.start(block)
            #endif
        }

        // 2) Atadığım işler başkası tarafından tamamlandı
        let completed = (try? context.fetch(Block.fetchAll(predicate: NSPredicate(
            format: "isDone == YES AND assignedByID_ == %@ AND doneByID_ != %@ AND doneAt_ > %@",
            myID, myID, Date.now.addingTimeInterval(-86_400) as NSDate)))) ?? []
        for block in completed {
            let key = "done-\(block.uuid)-\(block.doneAt_?.timeIntervalSince1970 ?? 0)"
            guard notified.insert(key).inserted, primed else { continue }
            await post(id: key, block: block,
                       title: "\(block.doneByName ?? block.assigneeName ?? "Bir ekip üyesi") görevi tamamladı ✓",
                       timeSensitive: false, actionable: false)
        }

        // 3) Yorumlar: benden bahsedildi, bana atanan ya da benim atadığım göreve yorum yapıldı
        let commentsPrimed = UserDefaults.standard.bool(forKey: commentsPrimedKey)
        let commentRequest = NSFetchRequest<Comment>(entityName: "Comment")
        commentRequest.predicate = NSPredicate(format: "createdAt_ > %@ AND authorID_ != %@",
                                               Date.now.addingTimeInterval(-3 * 86_400) as NSDate, myID)
        for comment in (try? context.fetch(commentRequest)) ?? [] {
            guard let block = comment.block else { continue }
            let key = "comment-\(comment.uuid)"
            guard notified.insert(key).inserted, commentsPrimed else { continue }
            let title: String
            if comment.mentionIDs.contains(myID) {
                title = "\(comment.authorName) senden bahsetti"
            } else if block.assigneeID == myID {
                title = "\(comment.authorName) görevine yorum yaptı"
            } else if block.assignedByID == myID {
                title = "\(comment.authorName) atadığın göreve yorum yaptı"
            } else {
                continue
            }
            await post(id: key, block: block, title: title, body: "„\(comment.text)“ — \(block.text)",
                       timeSensitive: false, actionable: false)
        }

        UserDefaults.standard.set(Array(notified.suffix(2000)), forKey: notifiedKey)
        UserDefaults.standard.set(true, forKey: primedKey)
        UserDefaults.standard.set(true, forKey: commentsPrimedKey)

        // 4) Son tarih hatırlatmaları: bana atanmış ya da kimseye atanmamış açık görevler
        let due = (try? context.fetch(Block.fetchAll(predicate: NSPredicate(
            format: "kind_ == %@ AND isDone == NO AND dueDate_ > %@", BlockKind.checklist.rawValue, Date.now as NSDate)))) ?? []
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("due-") }
        center.removePendingNotificationRequests(withIdentifiers: old)
        for block in due where block.assigneeID == nil || block.assigneeID == myID {
            guard let date = block.dueDate else { continue }
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            await post(id: "due-\(block.uuid)", block: block, title: "⏰ Süre doldu", timeSensitive: true,
                       trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        }

        #if os(iOS)
        LiveActivities.shared.refresh()
        #endif
        WidgetSync.update()
    }

    private func post(id: String, block: Block, title: String, body: String? = nil, timeSensitive: Bool,
                      actionable: Bool = true, trigger: UNNotificationTrigger? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = title
        let place: [String?] = [block.page?.notebook?.name, block.page?.title]
        content.subtitle = place.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        content.body = body ?? block.text
        content.sound = .default
        content.threadIdentifier = block.page?.uuid.uuidString ?? "devnote"
        content.userInfo = ["taskID": block.uuid.uuidString]
        if actionable { content.categoryIdentifier = Self.taskCategory }
        if timeSensitive { content.interruptionLevel = .timeSensitive }
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Uygulama ön plandayken de banner göster
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    // "Tamamla" düğmesi ya da bildirime dokunma
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let taskID = response.notification.request.content.userInfo["taskID"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            if let taskID {
                if action == Self.completeAction {
                    TaskActions.complete(taskID)
                } else if action == UNNotificationDefaultActionIdentifier {
                    TaskNotifier.shared.openTaskRequest = taskID
                }
            }
            completionHandler()
        }
    }
}

extension TaskNotifier: ObservableObject {}
