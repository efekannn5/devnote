import SwiftUI

enum Theme {
    static let palette = ["#0A84FF", "#5E5CE6", "#BF5AF2", "#FF375F", "#FF9F0A", "#FFD60A", "#30D158", "#64D2FF", "#8E8E93"]
    static let icons = ["book.closed.fill", "hammer.fill", "heart.fill", "lightbulb.fill", "briefcase.fill",
                        "graduationcap.fill", "person.2.fill", "star.fill", "flag.fill", "leaf.fill",
                        "cart.fill", "airplane", "terminal.fill", "paintpalette.fill"]
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.82)
    static let aiTint = Color(hex: "#BF5AF2")
}

extension Notebook {
    var color: Color { Color(hex: colorHex) }
}

/// Yapılacakların ilerleme halkası.
struct ProgressRing: View {
    var progress: Double
    var tint: Color
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(Theme.spring, value: progress)
    }
}

/// Yapay zekanın tamamladığı maddelerde görünen küçük rozet.
struct AIBadge: View {
    var note: String?
    @State private var showNote = false

    var body: some View {
        Button { showNote.toggle() } label: {
            Label("AI", systemImage: "sparkles")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.aiTint.opacity(0.15), in: Capsule())
                .foregroundStyle(Theme.aiTint)
        }
        .buttonStyle(.plain)
        .help(note ?? "Yapay zeka tarafından tamamlandı")
        .popover(isPresented: $showNote) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Yapay zeka tamamladı", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(Theme.aiTint)
                Text(note ?? "Açıklama bırakılmadı.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(maxWidth: 280)
        }
    }
}

extension EnvironmentValues {
    /// Açık sayfanın defterini paylaşan kişiler (atama menüsü için).
    @Entry var participants: [Person] = []
    /// Kullanıcı bu sayfayı düzenleyebilir mi? (salt okunur paylaşım)
    @Entry var canEditPage: Bool = true
}
