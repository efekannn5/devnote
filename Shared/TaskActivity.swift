import Foundation
import AppIntents
import SwiftUI
#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// Dynamic Island / kilit ekranında görünen görev. Uygulama ve widget eklentisi ortak kullanır.
struct TaskActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var pageTitle: String
        var assignedBy: String?
        var dueDate: Date?
        var isDone: Bool
        var doneCount: Int
        var totalCount: Int
    }

    /// Bloğun uuid'si
    var taskID: String
    var notebookName: String
    var notebookIcon: String
    var accentHex: String
}

/// Dynamic Island'daki ✓ butonu. `LiveActivityIntent` olduğu için uygulamanın kendi sürecinde çalışır
/// (gerekirse sistem uygulamayı arka planda açar); işi uygulama tarafındaki köprü yapar.
struct CompleteTaskIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Görevi tamamla"
    static var description = IntentDescription("Görevi tamamlandı olarak işaretler.")
    static var isDiscoverable = false

    @Parameter(title: "Görev") var taskID: String

    init() {}
    init(taskID: String) { self.taskID = taskID }

    func perform() async throws -> some IntentResult {
        await TaskIntentBridge.complete?(taskID)
        return .result()
    }
}

enum TaskIntentBridge {
    /// Uygulama açılışta doldurur; widget sürecinde boş kalır (orada çalışmaz).
    nonisolated(unsafe) static var complete: (@Sendable (String) async -> Void)?
}
#endif

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
