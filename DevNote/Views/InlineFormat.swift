import SwiftUI
import Combine

/// Satır içi biçim. Metinde Markdown olarak saklanır; böylece MCP / yapay zeka da aynı biçimi okur ve yazar.
enum InlineFormat: String, CaseIterable, Identifiable {
    case bold, italic, underline, strikethrough, code, link
    var id: String { rawValue }

    var title: String {
        switch self {
        case .bold: "Kalın"
        case .italic: "İtalik"
        case .underline: "Altı Çizili"
        case .strikethrough: "Üstü çizili"
        case .code: "Kod"
        case .link: "Bağlantı"
        }
    }

    var symbol: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .bold: "b"
        case .italic: "i"
        case .underline: "u"
        case .strikethrough: "x"
        case .code: "e"
        case .link: "k"
        }
    }

    var modifiers: EventModifiers { self == .strikethrough ? [.command, .shift] : .command }

    private var markers: (String, String) {
        switch self {
        case .bold: ("**", "**")
        case .italic: ("_", "_")
        case .underline: ("^[", "](underline: true)")
        case .strikethrough: ("~~", "~~")
        case .code: ("`", "`")
        case .link: ("[", "](https://)")
        }
    }

    /// Seçili aralığı biçimle (zaten biçimliyse biçimi kaldır). Seçim yoksa işaretleri imlecin olduğu yere koyar.
    /// Dönen `selection` karakter ofsetleridir.
    func apply(to text: String, selection: Range<Int>) -> (text: String, selection: Range<Int>) {
        let (open, close) = markers
        var chars = Array(text)
        let lower = max(0, min(selection.lowerBound, chars.count))
        let upper = max(lower, min(selection.upperBound, chars.count))
        let o = Array(open), c = Array(close)

        // Kaldırma: seçimin hemen dışında işaretler varsa
        if self != .link, self != .underline, lower >= o.count, upper + c.count <= chars.count,
           Array(chars[(lower - o.count)..<lower]) == o, Array(chars[upper..<(upper + c.count)]) == c {
            chars.removeSubrange(upper..<(upper + c.count))
            chars.removeSubrange((lower - o.count)..<lower)
            return (String(chars), (lower - o.count)..<(upper - o.count))
        }

        let selected = Array(chars[lower..<upper])
        chars.replaceSubrange(lower..<upper, with: o + selected + c)
        if self == .link {
            // Bağlantıda imleci URL'nin yerine koy
            let urlStart = lower + o.count + selected.count + 2
            return (String(chars), urlStart..<(urlStart + "https://".count))
        }
        return (String(chars), (lower + o.count)..<(lower + o.count + selected.count))
    }

    static func hasMarkup(_ text: String) -> Bool {
        text.contains("**") || text.contains("~~") || text.contains("`") || text.contains("](") || text.contains("*")
            || text.contains("\\")
            || text.range(of: #"(^|\W)_[^_\s][^_]*_(\W|$)"#, options: .regularExpression) != nil
    }

    static func rendered(_ text: String) -> AttributedString {
        RichText.display(text)
    }
}

/// Biçim işlemi (düğme, menü ya da kısayoldan)
enum FormatAction {
    case toggle(InlineFormat)
    case highlight(String?)      // nil = kaldır
    case color(String?)          // nil = varsayılan renk
    case size(Double?)           // punto (px); nil = bloğun normal boyutu
    case sizeStep(Double)        // +2 / -2
    case clear                   // tüm biçimi kaldır
}

/// Biçim düğmeleri / kısayolları → odaktaki satır. (Odaktaki satır dinleyip kendi seçimine uygular.)
final class FormatCommands: ObservableObject {
    static let shared = FormatCommands()
    let subject = PassthroughSubject<FormatAction, Never>()
    func send(_ action: FormatAction) { subject.send(action) }
    func send(_ format: InlineFormat) { subject.send(.toggle(format)) }
    /// Bloğun tamamına uygula (blok menüsünden renk / vurgu)
    let wholeBlock = PassthroughSubject<(UUID, FormatAction), Never>()
}

/// Mac menü çubuğundaki "Biçim" menüsü.
struct FormatMenuCommands: Commands {
    var body: some Commands {
        CommandMenu("Biçim") {
            ForEach(InlineFormat.allCases) { format in
                Button(format.title) { FormatCommands.shared.send(format) }
                    .keyboardShortcut(format.shortcut, modifiers: format.modifiers)
            }
            Divider()
            Menu("Vurgula") {
                ForEach(HighlightColor.allCases) { color in
                    Button(color.title) { FormatCommands.shared.send(.highlight(color.rawValue)) }
                }
                Divider()
                Button("Vurguyu Kaldır") { FormatCommands.shared.send(.highlight(nil)) }
            }
            Button("Sarı ile Vurgula") { FormatCommands.shared.send(.highlight(HighlightColor.yellow.rawValue)) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Menu("Yazı Rengi") {
                ForEach(TextColor.allCases) { color in
                    Button(color.title) { FormatCommands.shared.send(.color(color.rawValue)) }
                }
                Divider()
                Button("Varsayılan") { FormatCommands.shared.send(.color(nil)) }
            }
            Menu("Yazı Boyutu") {
                ForEach(TextSizes.presets, id: \.self) { size in
                    Button("\(Int(size)) px") { FormatCommands.shared.send(.size(size)) }
                }
            }
            Button("Büyüt") { FormatCommands.shared.send(.sizeStep(2)) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Küçült") { FormatCommands.shared.send(.sizeStep(-2)) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Normal Boyut") { FormatCommands.shared.send(.size(nil)) }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Biçimi Temizle") { FormatCommands.shared.send(.clear) }
                .keyboardShortcut("\\", modifiers: .command)
        }
    }
}

/// iPhone klavyesinin üstündeki biçim çubuğu.
struct FormatBar: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(InlineFormat.allCases) { format in
                    Button {
                        FormatCommands.shared.send(format)
                    } label: {
                        Image(systemName: format.symbol)
                    }
                    .accessibilityLabel(format.title)
                }
                Divider().frame(height: 18)
                Menu {
                    ForEach(HighlightColor.allCases) { color in
                        Button { FormatCommands.shared.send(.highlight(color.rawValue)) } label: {
                            Label { Text(color.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(color.color) }
                        }
                    }
                    Divider()
                    Button("Vurguyu Kaldır", systemImage: "xmark") { FormatCommands.shared.send(.highlight(nil)) }
                } label: {
                    Image(systemName: "highlighter")
                } primaryAction: {
                    FormatCommands.shared.send(.highlight(HighlightColor.yellow.rawValue))
                }
                .accessibilityLabel("Vurgula")
                Menu {
                    ForEach(TextColor.allCases) { color in
                        Button { FormatCommands.shared.send(.color(color.rawValue)) } label: {
                            Label { Text(color.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(color.color) }
                        }
                    }
                    Divider()
                    Button("Varsayılan", systemImage: "arrow.uturn.backward") { FormatCommands.shared.send(.color(nil)) }
                } label: {
                    Image(systemName: "paintpalette")
                }
                .accessibilityLabel("Yazı rengi")
                Menu {
                    Button("Büyüt", systemImage: "plus") { FormatCommands.shared.send(.sizeStep(2)) }
                    Button("Küçült", systemImage: "minus") { FormatCommands.shared.send(.sizeStep(-2)) }
                    Button("Normal", systemImage: "arrow.uturn.backward") { FormatCommands.shared.send(.size(nil)) }
                    Divider()
                    ForEach(TextSizes.presets.reversed(), id: \.self) { size in
                        Button("\(Int(size)) px") { FormatCommands.shared.send(.size(size)) }
                    }
                } label: {
                    Image(systemName: "textformat.size")
                }
                .accessibilityLabel("Yazı boyutu")
            }
            .padding(.horizontal, 4)
        }
    }
}
