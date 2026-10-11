import WidgetKit
import SwiftUI
import AppIntents

struct TasksEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct TasksProvider: TimelineProvider {
    func placeholder(in context: Context) -> TasksEntry {
        TasksEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (TasksEntry) -> Void) {
        let snapshot = WidgetSnapshot.load()
        completion(TasksEntry(date: .now, snapshot: context.isPreview && snapshot.tasks.isEmpty ? .preview : snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TasksEntry>) -> Void) {
        // Uygulama her değişiklikte yeniler; "1 saat kaldı" gibi göreli yazılar için saatlik yedek yenileme
        completion(Timeline(entries: [TasksEntry(date: .now, snapshot: WidgetSnapshot.load())],
                            policy: .after(.now.addingTimeInterval(3600))))
    }
}

/// Ana ekran ve kilit ekranı: açık görevler, ✓ ile uygulamayı açmadan tamamla.
struct TasksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DevNoteTasks", provider: TasksProvider()) { entry in
            TasksWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Görevlerim")
        .description("Açık görevlerin; dokunarak tamamla.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct TasksWidgetView: View {
    let entry: TasksEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: WidgetSnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(snapshot.openCount == 0 ? "Açık görev yok" : "\(snapshot.openCount) açık görev", systemImage: "checklist")
        case .accessoryCircular:
            Gauge(value: Double(snapshot.doneToday), in: 0...Double(max(1, snapshot.doneToday + snapshot.openCount))) {
                Image(systemName: "checklist")
            } currentValueLabel: {
                Text("\(snapshot.openCount)")
            }
            .gaugeStyle(.accessoryCircularCapacity)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("\(snapshot.openCount) açık görev", systemImage: "checklist").font(.headline)
                ForEach(snapshot.tasks.prefix(2)) { Text($0.title).lineLimit(1) }
            }
        default:
            list
        }
    }

    private var rows: Int {
        switch family {
        case .systemSmall: 3
        case .systemLarge: 7
        default: 4
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 8 : 5) {
            HStack(spacing: 6) {
                Image(systemName: "checklist").foregroundStyle(.tint)
                Text(family == .systemSmall ? "Görevler" : "Görevlerim").font(.headline)
                Spacer()
                Text("\(snapshot.openCount)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            if snapshot.tasks.isEmpty {
                Spacer()
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
                    Text("Hepsi bitti").font(.callout.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(snapshot.tasks.prefix(rows)) { task in
                    TaskRow(task: task, style: family == .systemSmall ? .small : family == .systemLarge ? .large : .medium)
                }
                Spacer(minLength: 0)
                if snapshot.tasks.count > rows, family == .systemLarge {
                    Text("+\(snapshot.tasks.count - rows) görev daha")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TaskRow: View {
    enum Style { case small, medium, large }
    let task: WidgetSnapshot.TaskItem
    let style: Style

    var body: some View {
        HStack(alignment: style == .large ? .top : .firstTextBaseline, spacing: 8) {
            Button(intent: CompleteTaskIntent(taskID: task.id)) {
                Image(systemName: "circle")
                    .font(style == .small ? .callout : .body)
                    .foregroundStyle(Color(hex: task.colorHex))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tamamla: \(task.title)")

            Link(destination: URL(string: "devnote://task/\(task.id)")!) {
                switch style {
                case .small:
                    Text(task.title).font(.caption).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .medium:
                    // Orta boyda tek satır: başlık + sağda kısa bilgi
                    HStack(spacing: 6) {
                        Text(task.title).font(.subheadline).lineLimit(1)
                        Spacer(minLength: 4)
                        detail.font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                case .large:
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.title).font(.subheadline).lineLimit(1)
                        detail.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let due = task.due {
            Label { Text(due, style: .relative) } icon: { Image(systemName: "bell.fill") }
                .foregroundStyle(due < .now ? .red : .orange)
        } else if let by = task.assignedBy {
            Label(by, systemImage: "person.fill")
        } else {
            Text(task.page)
        }
    }
}

extension WidgetSnapshot {
    static let preview = WidgetSnapshot(tasks: [
        .init(id: "1", title: "Sunum slaytlarını hazırla", page: "Sprint", notebook: "Ekip", colorHex: "#0A84FF",
              due: .now.addingTimeInterval(3600), assignedBy: "Ayşe", isAssignedToMe: true),
        .init(id: "2", title: "Müşteri notlarını paylaş", page: "Toplantı", notebook: "Ekip", colorHex: "#FF9F0A",
              due: nil, assignedBy: nil, isAssignedToMe: false),
        .init(id: "3", title: "Tasarım ekranlarını bitir", page: "Tasarım", notebook: "Proje", colorHex: "#30D158",
              due: nil, assignedBy: "Ali", isAssignedToMe: true),
    ], openCount: 3, doneToday: 2, updatedAt: .now)
}

#Preview(as: .systemMedium) {
    TasksWidget()
} timeline: {
    TasksEntry(date: .now, snapshot: .preview)
}
