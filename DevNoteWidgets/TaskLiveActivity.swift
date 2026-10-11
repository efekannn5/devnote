import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct DevNoteWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TasksWidget()
        TaskLiveActivity()
    }
}

struct TaskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskActivityAttributes.self) { context in
            LockScreenTaskView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let accent = Color(hex: context.attributes.accentHex)
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.attributes.notebookIcon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accent)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DueLabel(due: state.dueDate, isDone: state.isDone)
                        .font(.caption.weight(.semibold))
                        .frame(width: 64, alignment: .trailing)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title)
                        .font(.headline)
                        .strikethrough(state.isDone)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            if let by = state.assignedBy {
                                Label("\(by) atadı", systemImage: "person.fill")
                            }
                            Label("\(context.attributes.notebookName) · \(state.pageTitle) · \(state.doneCount)/\(state.totalCount)", systemImage: "doc.text")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        Spacer()
                        CompleteButton(taskID: context.attributes.taskID, isDone: state.isDone, accent: accent)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                }
            } compactLeading: {
                ProgressGlyph(done: state.doneCount, total: state.totalCount, isDone: state.isDone, accent: accent)
            } compactTrailing: {
                if state.isDone {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                } else if state.dueDate != nil {
                    DueLabel(due: state.dueDate, isDone: false, showsIcon: false)
                        .font(.caption2.weight(.semibold))
                        .frame(width: 40)
                } else {
                    Text("\(state.doneCount)/\(state.totalCount)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(accent)
                }
            } minimal: {
                ProgressGlyph(done: state.doneCount, total: state.totalCount, isDone: state.isDone, accent: accent)
            }
            .widgetURL(URL(string: "devnote://task/\(context.attributes.taskID)"))
            .keylineTint(accent)
        }
    }
}

struct LockScreenTaskView: View {
    let context: ActivityViewContext<TaskActivityAttributes>

    var body: some View {
        let accent = Color(hex: context.attributes.accentHex)
        let state = context.state
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent.gradient)
                Image(systemName: state.isDone ? "checkmark" : context.attributes.notebookIcon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(context.attributes.notebookName) · \(state.pageTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(state.title)
                    .font(.headline)
                    .strikethrough(state.isDone)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let by = state.assignedBy {
                        Label(by, systemImage: "person.fill")
                    }
                    DueLabel(due: state.dueDate, isDone: state.isDone)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            CompleteButton(taskID: context.attributes.taskID, isDone: state.isDone, accent: accent)
        }
        .padding(16)
    }
}

struct CompleteButton: View {
    let taskID: String
    let isDone: Bool
    let accent: Color

    var body: some View {
        if isDone {
            Label("Tamamlandı", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        } else {
            Button(intent: CompleteTaskIntent(taskID: taskID)) {
                Label("Tamamla", systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(accent)
        }
    }
}

/// Son tarihe geri sayım (geçtiyse "Gecikti").
struct DueLabel: View {
    let due: Date?
    let isDone: Bool
    var showsIcon = true

    var body: some View {
        if isDone {
            Text("Bitti").foregroundStyle(.green)
        } else if let due {
            if due > .now {
                HStack(spacing: 3) {
                    if showsIcon { Image(systemName: "bell.fill") }
                    Text(timerInterval: Date.now...due, countsDown: true)
                        .monospacedDigit()
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                }
                .foregroundStyle(.orange)
            } else {
                Label("Gecikti", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
        } else {
            Text("Süre yok").foregroundStyle(.secondary)
        }
    }
}

struct ProgressGlyph: View {
    let done: Int
    let total: Int
    let isDone: Bool
    let accent: Color

    var body: some View {
        let progress = total == 0 ? 0 : Double(done) / Double(total)
        ZStack {
            Circle().stroke(accent.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: isDone ? 1 : progress)
                .stroke(isDone ? .green : accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: isDone ? "checkmark" : "checklist")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isDone ? .green : accent)
        }
        .frame(width: 20, height: 20)
    }
}
