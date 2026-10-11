import Foundation

/// Uygulamanın widget için yazdığı görev özeti (App Group kapsayıcısında JSON).
/// Widget Core Data'ya dokunmaz; yalnızca bu dosyayı okur.
struct WidgetSnapshot: Codable {
    struct TaskItem: Codable, Identifiable, Hashable {
        var id: String          // bloğun uuid'si
        var title: String
        var page: String
        var notebook: String
        var colorHex: String
        var due: Date?
        var assignedBy: String?
        var isAssignedToMe: Bool
    }

    var tasks: [TaskItem]
    var openCount: Int
    var doneToday: Int
    var updatedAt: Date

    static let appGroup = "group.com.efekan.devnote"
    static let empty = WidgetSnapshot(tasks: [], openCount: 0, doneToday: 0, updatedAt: .distantPast)

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "widget-tasks.json")
    }

    static func load() -> WidgetSnapshot {
        guard let url, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    /// Yazıldıysa true (içerik değişmediyse yazmaz, widget'ı boşuna yenilemeyelim)
    @discardableResult
    func save() -> Bool {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return false }
        var old = Self.load()
        old.updatedAt = updatedAt
        if (try? JSONEncoder().encode(old)) == data { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
