import SwiftUI
import Combine

/// Biçim çubuğunun gösterdiği / uyguladığı durum. Yalnızca biçim çubukları izler (bloklar izlemez,
/// yoksa her imleç hareketinde tüm sayfa yeniden çizilirdi).
@MainActor
final class FormatState: ObservableObject {
    static let shared = FormatState()

    /// Biçimin uygulanacağı blok. Odak biçim çubuğuna (ör. boyut kutusu) geçse de kalır.
    @Published var activeBlockID: UUID?
    @Published var kind: BlockKind = .text
    @Published var bold = false
    @Published var italic = false
    @Published var underline = false
    @Published var strikethrough = false
    @Published var code = false
    @Published var link = false
    @Published var pointSize: Double = 17

    /// Biçim çubuğundaki bir alan (ör. boyut kutusu) düzenleniyor: blok odağı kaybetse de "boş kutu" sayılıp silinmesin
    var editingToolbar = false

    /// Bir sonraki odaklanmada imlecin gideceği karakter konumu (blok bölme / birleştirme sonrası)
    var pendingCursor: [UUID: Int] = [:]

    func update(kind: BlockKind, bold: Bool, italic: Bool, underline: Bool, strikethrough: Bool,
                code: Bool, link: Bool, pointSize: Double) {
        // Değişmeyen değerleri yeniden yayınlama
        if self.kind != kind { self.kind = kind }
        if self.bold != bold { self.bold = bold }
        if self.italic != italic { self.italic = italic }
        if self.underline != underline { self.underline = underline }
        if self.strikethrough != strikethrough { self.strikethrough = strikethrough }
        if self.code != code { self.code = code }
        if self.link != link { self.link = link }
        if abs(self.pointSize - pointSize) > 0.4 { self.pointSize = pointSize }
    }
}

/// "/" komut menüsü
@MainActor
final class SlashMenuState: ObservableObject {
    static let shared = SlashMenuState()

    struct Session: Equatable {
        var blockID: UUID
        var query: String
        var highlighted = 0
    }

    @Published var session: Session?
    /// Seçilen tür → ilgili editör uygular
    let picked = PassthroughSubject<(UUID, BlockKind), Never>()

    var results: [BlockKind] { session.map { Self.filter($0.query) } ?? [] }

    static func filter(_ query: String) -> [BlockKind] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased(with: Locale(identifier: "tr"))
        guard !q.isEmpty else { return BlockKind.insertable }
        return BlockKind.insertable.filter { kind in
            kind.title.lowercased(with: Locale(identifier: "tr")).contains(q)
                || kind.keywords.contains { $0.hasPrefix(q) }
                || kind.shortcut == q
        }
    }

    func pick(_ kind: BlockKind) {
        guard let session else { return }
        picked.send((session.blockID, kind))
    }

    func move(_ delta: Int) {
        guard var session, !results.isEmpty else { return }
        session.highlighted = (session.highlighted + delta + results.count) % results.count
        self.session = session
    }

    func pickHighlighted() {
        guard let session, results.indices.contains(session.highlighted) else { return }
        pick(results[session.highlighted])
    }
}

/// Fotoğraf seçiciyi açma isteği ("/" menüsünden Görsel)
@MainActor
final class EditorRequests: ObservableObject {
    static let shared = EditorRequests()
    /// Bu bloğun yerine / arkasına görsel eklenecek
    let pickPhoto = PassthroughSubject<UUID, Never>()
    /// Bu bloğun sonuna Markdown metni ekle (⌫ ile birleştirme). Editör biçimleri bozmadan birleştirir;
    /// Markdown'ı düz birleştirmek "**a****b**" gibi bozuk sonuç verir.
    let append = PassthroughSubject<(UUID, String), Never>()
}
