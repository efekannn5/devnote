import SwiftUI

// Zengin metin: blok metni Markdown olarak saklanır (yapay zeka / MCP / diğer platformlar okur),
// editörde ise işaretler görünmez — doğrudan kalın, italik, vurgulu yazılır.
//   **kalın**  *italik*  ~~üstü çizili~~  `kod`  [bağlantı](https://…)
//   ^[vurgulu](highlight: '#FFD60A')   ^[renkli](color: '#FF453A')   ^[altı çizili](underline: true)
//   ^[büyük](size: 24)    — punto (px)

/// Markdown'daki özel öznitelikler: ^[metin](highlight: '#RRGGBB', color: '#RRGGBB')
struct DevNoteAttributes: AttributeScope {
    let highlight: HighlightKey
    let color: TextColorKey
    let underline: UnderlineKey
    let size: SizeKey
    let foundation: AttributeScopes.FoundationAttributes

    enum UnderlineKey: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
        typealias Value = Bool
        static let name = "underline"
    }

    enum SizeKey: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
        typealias Value = Double
        static let name = "size"
    }

    enum HighlightKey: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
        typealias Value = String
        static let name = "highlight"
    }

    enum TextColorKey: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
        typealias Value = String
        static let name = "color"
    }
}

extension AttributeScopes {
    var devNote: DevNoteAttributes.Type { DevNoteAttributes.self }
}

extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<DevNoteAttributes, T>) -> T { self[T.self] }
}

/// Vurgu renkleri (Windows / web sürümünde de aynı değerler)
enum HighlightColor: String, CaseIterable, Identifiable {
    case yellow = "#FFD60A", green = "#30D158", blue = "#64D2FF", pink = "#FF6FAE", purple = "#BF5AF2", orange = "#FF9F0A"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .yellow: "Sarı"
        case .green: "Yeşil"
        case .blue: "Mavi"
        case .pink: "Pembe"
        case .purple: "Mor"
        case .orange: "Turuncu"
        }
    }

    var color: Color { Color(hex: rawValue) }
}

/// Yazı rengi seçenekleri
enum TextColor: String, CaseIterable, Identifiable {
    case red = "#FF453A", orange = "#FF9F0A", green = "#30D158", blue = "#0A84FF", purple = "#BF5AF2", gray = "#8E8E93"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .red: "Kırmızı"
        case .orange: "Turuncu"
        case .green: "Yeşil"
        case .blue: "Mavi"
        case .purple: "Mor"
        case .gray: "Gri"
        }
    }

    var color: Color { Color(hex: rawValue) }
}

/// Yazı boyutu (punto ≈ px)
enum TextSizes {
    static let presets: [Double] = [10, 12, 14, 15, 17, 20, 24, 28, 32, 40, 48, 64]
    static let range: ClosedRange<Double> = 8...96

    /// Kayıtlı değer → punto. (İlk sürümde oran saklanıyordu: 4 ve altı orandır.)
    static func points(_ stored: Double, base: CGFloat) -> CGFloat {
        stored <= 4 ? base * stored : stored
    }
}

/// Bloğun temel yazı biçimi (editör ölçüleri buna göre)
struct BaseStyle {
    var font: Font
    var pointSize: CGFloat
    var bold: Bool
    var italic: Bool

    /// Belirli puntoda, temel kalınlık / eğiklik korunarak
    func font(size: CGFloat) -> Font {
        var f = Font.system(size: size)
        if bold { f = f.bold() }
        if italic { f = f.italic() }
        return f
    }
}

enum RichText {
    /// Vurgunun ekrandaki dolgusu: metin açık ve koyu temada okunur kalsın
    static func fill(_ hex: String) -> Color { Color(hex: hex).opacity(0.38) }

    static func parse(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, including: \.devNote,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }

    /// Salt görünüm (Text): Markdown biçimi + vurgu / renk
    /// - base: boyutlu metin için bloğun yazı boyutu (punto)
    static func display(_ markdown: String, base: CGFloat? = 17) -> AttributedString {
        var text = parse(markdown)
        for run in text.runs {
            if let hex = run[DevNoteAttributes.HighlightKey.self] { text[run.range].backgroundColor = fill(hex) }
            if let hex = run[DevNoteAttributes.TextColorKey.self] { text[run.range].foregroundColor = Color(hex: hex) }
            if run[DevNoteAttributes.UnderlineKey.self] == true { text[run.range].underlineStyle = .single }
            if let size = run[DevNoteAttributes.SizeKey.self], let base {
                text[run.range].font = Font.system(size: TextSizes.points(size, base: base))
            }
        }
        return text
    }

    /// Editör (TextEditor): biçim SwiftUI fontu / öznitelikleriyle; Markdown işaretleri yok
    static func editable(_ markdown: String, base: BaseStyle) -> AttributedString {
        editable(parse(markdown), base: base)
    }

    static func editable(_ parsed: AttributedString, base: BaseStyle) -> AttributedString {
        var text = AttributedString(parsed.characters)   // öznitelikleri baştan kur
        for run in parsed.runs {
            let range = run.range
            let intent = run.inlinePresentationIntent ?? []
            let size = run[DevNoteAttributes.SizeKey.self].map { TextSizes.points($0, base: base.pointSize) }
            if intent.contains(.stronglyEmphasized) || intent.contains(.emphasized) || intent.contains(.code) || size != nil {
                var font = size.map { base.font(size: $0) } ?? base.font
                if intent.contains(.stronglyEmphasized) { font = font.bold() }
                if intent.contains(.emphasized) { font = font.italic() }
                if intent.contains(.code) { font = font.monospaced() }
                text[range].font = font
            }
            if intent.contains(.strikethrough) { text[range].strikethroughStyle = .single }
            if run[DevNoteAttributes.UnderlineKey.self] == true { text[range].underlineStyle = .single }
            if let url = run.link { text[range].link = url }
            if let hex = run[DevNoteAttributes.HighlightKey.self] { text[range].backgroundColor = fill(hex) }
            if let hex = run[DevNoteAttributes.TextColorKey.self] { text[range].foregroundColor = Color(hex: hex) }
        }
        return text
    }

    private struct Style: Equatable {
        var bold = false, italic = false, code = false, strike = false, underline = false
        var size: Int?
        var link: URL?
        var highlight: String?
        var color: String?
    }

    /// Editördeki metni Markdown'a çevirir.
    @available(iOS 26.0, macOS 26.0, *)
    static func markdown(from text: AttributedString, base: Font, context: Font.Context,
                         environment: EnvironmentValues) -> String {
        let baseFont = base.resolve(in: context)
        var groups: [(Style, String)] = []
        for run in text.runs {
            var style = Style()
            if let font = run.font {
                let resolved = font.resolve(in: context)
                style.bold = resolved.isBold && !baseFont.isBold
                style.italic = resolved.isItalic && !baseFont.isItalic
                style.code = resolved.isMonospaced && !baseFont.isMonospaced
                if abs(resolved.pointSize - baseFont.pointSize) > 0.5 { style.size = Int(resolved.pointSize.rounded()) }
            }
            style.strike = run.strikethroughStyle != nil
            style.underline = run.underlineStyle != nil
            style.link = run.link
            style.highlight = run.backgroundColor.flatMap { hex($0, in: environment) }
            style.color = run.foregroundColor.flatMap { hex($0, in: environment) }
            let piece = String(text[run.range].characters)
            if let last = groups.last, last.0 == style {
                groups[groups.count - 1].1 += piece
            } else {
                groups.append((style, piece))
            }
        }
        return groups.map { wrap($0.1, $0.0) }.joined()
    }

    private static func wrap(_ text: String, _ style: Style) -> String {
        guard style != Style() else { return escape(text) }
        // İşaretler boşluğa yapışırsa Markdown biçimi tanımaz: baştaki / sondaki boşluklar dışarıda kalsın
        let core = text.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return text }
        let lead = String(text.prefix(while: { $0 == " " }))
        let trail = String(text.reversed().prefix(while: { $0 == " " }))
        var s = style.code ? "`\(core)`" : escape(core)
        if style.strike { s = "~~\(s)~~" }
        if style.italic { s = "*\(s)*" }
        if style.bold { s = "**\(s)**" }
        if let link = style.link {
            let url = link.absoluteString
            s = "[\(s)](\(url.contains(" ") || url.contains(")") ? "<\(url)>" : url))"
        }
        var attributes: [String] = []
        if let highlight = style.highlight { attributes.append("highlight: '\(highlight)'") }
        if let color = style.color { attributes.append("color: '\(color)'") }
        if style.underline { attributes.append("underline: true") }
        if let size = style.size { attributes.append("size: \(size)") }
        if !attributes.isEmpty { s = "^[\(s)](\(attributes.joined(separator: ", ")))" }
        return lead + s + trail
    }

    /// Düz metindeki Markdown karakterleri biçim sanılmasın
    static func escape(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\*_`[]~^".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Renk → "#RRGGBB" (sRGB; saydamlık yok sayılır)
    static func hex(_ color: Color, in environment: EnvironmentValues) -> String? {
        let resolved = color.resolve(in: environment)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = resolved.cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = cg.components, c.count >= 3 else { return nil }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c[0]), byte(c[1]), byte(c[2]))
    }
}
