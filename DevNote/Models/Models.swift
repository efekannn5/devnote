import Foundation
import CoreData
import CloudKit

// Yerel depo Core Data; iCloud senkronu CKSyncEngine ile (bkz. CloudSync).
//
// Her nesne bir CloudKit bölgesine (zone) aittir: her defter kendi bölgesindedir, sayfaları ve
// blokları da onunla aynı bölgede. CloudKit kayıt adı "<Entity>.<uuid>" — bu yüzden aynı nesne
// iki kez oluşamaz. Nesne türündeki alanlar `_` son ekiyle opsiyonel saklanıyor ve güvenli bir
// erişimciyle açılıyor; böylece silinmiş bir nesneye dokunan bir görünüm çökmüyor.

enum PageLayout: String, CaseIterable, Identifiable {
    case document, canvas
    var id: String { rawValue }
    var title: String { self == .document ? "Belge" : "Tuval" }
    var symbol: String { self == .document ? "doc.text" : "square.on.square.dashed" }
}

enum BlockKind: String, CaseIterable, Identifiable {
    // Ham değerler kayıtlıdır (iCloud); yenileri sona eklenir. Bilmeyen eski sürümler "metin" gösterir.
    case text, heading, heading2, heading3, checklist, bullet, numbered, quote, code, divider, image
    var id: String { rawValue }

    /// "Dönüştür" menüsündeki metin türleri
    static var textKinds: [BlockKind] { allCases.filter { $0 != .image && $0 != .divider } }
    /// "+" menüsündeki tüm türler (Notion sırası)
    static var insertable: [BlockKind] { [.text, .heading, .heading2, .heading3, .bullet, .numbered, .checklist, .quote, .code, .divider, .image] }

    var title: String {
        switch self {
        case .text: "Metin"
        case .heading: "Başlık 1"
        case .heading2: "Başlık 2"
        case .heading3: "Başlık 3"
        case .checklist: "Yapılacak"
        case .bullet: "Madde işaretli liste"
        case .numbered: "Numaralı liste"
        case .quote: "Alıntı"
        case .code: "Kod"
        case .divider: "Ayırıcı"
        case .image: "Görsel"
        }
    }

    var symbol: String {
        switch self {
        case .text: "textformat"
        case .heading: "textformat.size.larger"
        case .heading2: "textformat.size"
        case .heading3: "textformat.size.smaller"
        case .checklist: "checklist"
        case .bullet: "list.bullet"
        case .numbered: "list.number"
        case .quote: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .divider: "minus"
        case .image: "photo"
        }
    }

    /// Markdown kısayolu (menüde sağda gösterilir; satır başına yazınca dönüştürür)
    var shortcut: String? {
        switch self {
        case .heading: "#"
        case .heading2: "##"
        case .heading3: "###"
        case .checklist: "[]"
        case .bullet: "-"
        case .numbered: "1."
        case .quote: ">"
        case .code: "```"
        case .divider: "---"
        default: nil
        }
    }

    /// "/" menüsünde aranan diğer adlar
    var keywords: [String] {
        switch self {
        case .text: ["metin", "paragraf", "text", "normal"]
        case .heading: ["başlık", "h1", "heading"]
        case .heading2: ["başlık", "h2", "heading"]
        case .heading3: ["başlık", "h3", "heading"]
        case .checklist: ["yapılacak", "görev", "todo", "to-do", "checkbox"]
        case .bullet: ["madde", "liste", "bullet", "list"]
        case .numbered: ["numaralı", "sıralı", "liste", "numbered", "list"]
        case .quote: ["alıntı", "quote"]
        case .code: ["kod", "code"]
        case .divider: ["ayırıcı", "çizgi", "divider", "line"]
        case .image: ["görsel", "fotoğraf", "resim", "image", "photo"]
        }
    }

    var isHeading: Bool { self == .heading || self == .heading2 || self == .heading3 }
    /// Enter'a basınca bir sonraki satır aynı türde devam eder
    var continuesOnEnter: Bool { self == .checklist || self == .bullet || self == .numbered }
    /// İçine yazı yazılan tür
    var hasText: Bool { self != .divider }
}

/// Markdown metnini bloklara ayırır (yapıştırma, yapay zeka / MCP). Satır içi biçim Markdown olarak kalır.
enum MarkdownBlocks {
    struct Item: Equatable {
        var kind: BlockKind
        var text: String
        var indent: Int = 0
        var isDone = false
    }

    /// Metin Markdown blok sözdizimi içeriyor mu (yapıştırınca bloklara bölmeye değer mi)
    static func looksStructured(_ text: String) -> Bool {
        text.contains("\n")
    }

    static func parse(_ markdown: String) -> [Item] {
        var items: [Item] = []
        var codeLines: [String]?
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = codeLines {
                    items.append(Item(kind: .code, text: lines.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    codeLines = []
                }
                continue
            }
            if codeLines != nil { codeLines?.append(raw); continue }
            if trimmed.isEmpty { continue }
            let leading = raw.prefix { $0 == " " || $0 == "\t" }
            let indent = min(6, leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2)
            items.append(item(for: trimmed, indent: indent))
        }
        if let lines = codeLines, !lines.isEmpty { items.append(Item(kind: .code, text: lines.joined(separator: "\n"))) }
        return items
    }

    /// Tek satır → blok
    static func item(for line: String, indent: Int = 0) -> Item {
        func rest(_ n: Int) -> String { String(line.dropFirst(n)).trimmingCharacters(in: .whitespaces) }
        let lower = line.lowercased()
        if ["---", "***", "___"].contains(line.replacingOccurrences(of: " ", with: "")) { return Item(kind: .divider, text: "") }
        if lower.hasPrefix("- [x] ") || lower.hasPrefix("* [x] ") { return Item(kind: .checklist, text: rest(6), indent: indent, isDone: true) }
        if line.hasPrefix("- [ ] ") || line.hasPrefix("* [ ] ") { return Item(kind: .checklist, text: rest(6), indent: indent) }
        if line.hasPrefix("[] ") { return Item(kind: .checklist, text: rest(3), indent: indent) }
        if line.hasPrefix("### ") { return Item(kind: .heading3, text: rest(4)) }
        if line.hasPrefix("## ") { return Item(kind: .heading2, text: rest(3)) }
        if line.hasPrefix("# ") { return Item(kind: .heading, text: rest(2)) }
        if line.hasPrefix("#### ") { return Item(kind: .heading3, text: rest(5)) }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") { return Item(kind: .bullet, text: rest(2), indent: indent) }
        if let match = line.firstMatch(of: #/^\d{1,3}[.)] /#) { return Item(kind: .numbered, text: rest(match.output.count), indent: indent) }
        if line.hasPrefix("> ") { return Item(kind: .quote, text: rest(2)) }
        return Item(kind: .text, text: line, indent: indent)
    }
}

/// Bir maddeyi kimin tamamladığı.
enum Completer: String {
    case human, ai
}

// MARK: - Notebook

@objc(Notebook)
final class Notebook: NSManagedObject, Identifiable {
    var id: UUID { uuid }

    @NSManaged var uuid_: UUID?
    @NSManaged var name_: String?
    @NSManaged var icon_: String?
    @NSManaged var colorHex_: String?
    @NSManaged var sortIndex: Int64
    @NSManaged var createdAt_: Date?
    @NSManaged var pages_: NSSet?

    // Senkron meta verisi
    @NSManaged var zoneName_: String?
    @NSManaged var zoneOwner_: String?
    @NSManaged var ckSystemFields_: Data?
    @NSManaged var modifiedAt_: Date?

    var uuid: UUID { uuid_ ?? UUID() }
    var name: String { get { name_ ?? "" } set { name_ = newValue } }
    var icon: String { get { icon_ ?? "book.closed.fill" } set { icon_ = newValue } }
    var colorHex: String { get { colorHex_ ?? "#0A84FF" } set { colorHex_ = newValue } }
    var pages: [Page] { (pages_ as? Set<Page>).map(Array.init) ?? [] }

    override func awakeFromInsert() {
        super.awakeFromInsert()
        uuid_ = UUID()
        createdAt_ = .now
    }

    @discardableResult
    static func create(name: String, icon: String = "book.closed.fill", colorHex: String = "#0A84FF",
                       sortIndex: Int = 0, in context: NSManagedObjectContext) -> Notebook {
        let nb = Notebook(entity: DataModel.entity("Notebook"), insertInto: context)
        nb.name = name
        nb.icon = icon
        nb.colorHex = colorHex
        nb.sortIndex = Int64(sortIndex)
        nb.zoneName_ = "nb-\(nb.uuid.uuidString)"
        nb.zoneOwner_ = CKCurrentUserDefaultName
        return nb
    }
}

// MARK: - Page

@objc(Page)
final class Page: NSManagedObject, Identifiable {
    var id: UUID { uuid }

    @NSManaged var uuid_: UUID?
    @NSManaged var title_: String?
    @NSManaged var layout_: String?
    @NSManaged var isPinned: Bool
    @NSManaged var createdAt_: Date?
    @NSManaged var updatedAt_: Date?
    @NSManaged var notebook: Notebook?
    @NSManaged var blocks_: NSSet?
    @NSManaged var parentUUID_: UUID?
    /// Tuvaldeki çizim (PencilKit `PKDrawing.dataRepresentation()`)
    @NSManaged var drawing_: Data?
    @NSManaged var authorName_: String?
    /// En son düzenleyen kişi (paylaşılan defterlerde "Ayşe düzenledi" için)
    @NSManaged var lastEditorName_: String?

    // Senkron meta verisi
    @NSManaged var zoneName_: String?
    @NSManaged var zoneOwner_: String?
    @NSManaged var ckSystemFields_: Data?
    @NSManaged var modifiedAt_: Date?

    var uuid: UUID { uuid_ ?? UUID() }
    var title: String { get { title_ ?? "" } set { title_ = newValue } }
    var updatedAt: Date { updatedAt_ ?? .distantPast }

    var layout: PageLayout {
        get { PageLayout(rawValue: layout_ ?? "") ?? .document }
        set { layout_ = newValue.rawValue }
    }

    override func awakeFromInsert() {
        super.awakeFromInsert()
        uuid_ = UUID()
        createdAt_ = .now
        updatedAt_ = .now
    }

    @discardableResult
    static func create(title: String, notebook: Notebook?, layout: PageLayout = .document,
                       in context: NSManagedObjectContext) -> Page {
        let page = Page(entity: DataModel.entity("Page"), insertInto: context)
        page.title = title
        page.layout = layout
        page.authorName_ = Persistence.shared.myDisplayName(for: notebook)
        if let notebook { page.move(to: notebook) }
        return page
    }

    var sortedBlocks: [Block] {
        ((blocks_ as? Set<Block>) ?? []).filter { !$0.isDeleted }.sorted { $0.order < $1.order }
    }

    var tasks: [Block] { sortedBlocks.filter { $0.kind == .checklist } }
    var openTaskCount: Int { tasks.filter { !$0.isDone }.count }
    var hasAICompletions: Bool { tasks.contains { $0.doneBy == .ai } }

    var progress: Double {
        let all = tasks
        guard !all.isEmpty else { return 0 }
        return Double(all.filter(\.isDone).count) / Double(all.count)
    }

    var snippet: String {
        sortedBlocks.lazy.map(\.text).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }

    func touch() {
        updatedAt_ = .now
        let me = Persistence.shared.myDisplayName(for: notebook)
        if lastEditorName_ != me { lastEditorName_ = me }
    }

    /// Sayfayı (ve bloklarını) başka bir deftere / CloudKit bölgesine taşır.
    func move(to notebook: Notebook) {
        self.notebook = notebook
        zoneName_ = notebook.zoneName_
        zoneOwner_ = notebook.zoneOwner_
        for block in sortedBlocks {
            block.zoneName_ = notebook.zoneName_
            block.zoneOwner_ = notebook.zoneOwner_
            for comment in block.comments {
                comment.zoneName_ = notebook.zoneName_
                comment.zoneOwner_ = notebook.zoneOwner_
            }
        }
        touch()
    }

    /// Yeni blok ekler. `after` verilirse onun hemen arkasına yerleştirir.
    @discardableResult
    func addBlock(_ kind: BlockKind, text: String = "", after: Block? = nil,
                  in context: NSManagedObjectContext) -> Block {
        let blocks = sortedBlocks
        let order: Double
        if let after, let idx = blocks.firstIndex(of: after) {
            let next = idx + 1 < blocks.count ? blocks[idx + 1].order : after.order + 2
            order = (after.order + next) / 2
        } else {
            order = (blocks.last?.order ?? 0) + 1
        }
        let block = Block(entity: DataModel.entity("Block"), insertInto: context)
        block.kind = kind
        block.text = text
        block.order = order
        block.indent = after?.indent ?? 0
        block.authorName_ = Persistence.shared.myDisplayName(for: notebook)
        block.zoneName_ = zoneName_
        block.zoneOwner_ = zoneOwner_
        block.page = self
        touch()
        return block
    }
}

extension Page {
    /// Bloğu `target`ın önüne taşır (`target` nil ise sona). Diğer blokların sırası değişmez.
    func move(_ block: Block, before target: Block?) {
        let others = sortedBlocks.filter { $0 != block }
        guard let target, let index = others.firstIndex(of: target) else {
            block.order = (others.last?.order ?? 0) + 1
            touch()
            return
        }
        let previous = index > 0 ? others[index - 1].order : target.order - 2
        block.order = (previous + target.order) / 2
        touch()
    }

    /// Bloğu bir yukarı / aşağı kaydırır.
    func shift(_ block: Block, by delta: Int) {
        let blocks = sortedBlocks
        guard let index = blocks.firstIndex(of: block) else { return }
        let destination = index + delta
        guard destination >= 0, destination < blocks.count else { return }
        if delta < 0 {
            move(block, before: blocks[destination])
        } else {
            move(block, before: destination + 1 < blocks.count ? blocks[destination + 1] : nil)
        }
    }

    /// Numaralı liste maddesinin sırası (aynı girintideki ardışık numaralı maddeler)
    func listNumber(of block: Block) -> Int? {
        guard block.kind == .numbered else { return nil }
        let blocks = sortedBlocks
        guard var index = blocks.firstIndex(of: block) else { return nil }
        var number = 1
        while index > 0 {
            index -= 1
            let previous = blocks[index]
            if previous.indent > block.indent { continue }          // iç içe alt maddeler sayılmaz
            guard previous.kind == .numbered, previous.indent == block.indent else { break }
            number += 1
        }
        return number
    }

    /// Markdown bloklarını `after`ın arkasına sırayla ekler; eklenen son bloğu döndürür.
    @discardableResult
    func insert(_ items: [MarkdownBlocks.Item], after: Block?, in context: NSManagedObjectContext) -> Block? {
        var anchor = after
        for item in items {
            let block = addBlock(item.kind, text: item.text, after: anchor, in: context)
            block.indent = Int64(item.indent)
            if item.isDone { block.setDone(true, by: .human) }
            anchor = block
        }
        return anchor
    }

    /// Bloktan önceki blok
    func block(before block: Block) -> Block? {
        let blocks = sortedBlocks
        guard let index = blocks.firstIndex(of: block), index > 0 else { return nil }
        return blocks[index - 1]
    }
}

// MARK: - Block

@objc(Block)
final class Block: NSManagedObject, Identifiable {
    var id: UUID { uuid }

    @NSManaged var uuid_: UUID?
    @NSManaged var kind_: String?
    @NSManaged var text_: String?
    @NSManaged var order: Double
    @NSManaged var indent: Int64
    @NSManaged var createdAt_: Date?
    @NSManaged var authorName_: String?

    // Yapılacak maddeler
    @NSManaged var isDone: Bool
    @NSManaged var doneBy_: String?
    @NSManaged var doneAt_: Date?
    /// Yapay zekanın "ne yaptım" açıklaması.
    @NSManaged var doneNote_: String?
    /// Tamamlayan kişi (atayana "X tamamladı" bildirimi için)
    @NSManaged var doneByID_: String?
    @NSManaged var doneByName_: String?

    // Atama & hatırlatma
    /// Atanan kişinin CloudKit kullanıcı kaydı adı (userRecordID.recordName).
    @NSManaged var assigneeID_: String?
    @NSManaged var assigneeName_: String?
    @NSManaged var assignedByID_: String?
    @NSManaged var assignedByName_: String?
    @NSManaged var dueDate_: Date?
    @NSManaged var assignedAt_: Date?

    /// Görsel bloğu: küçültülmüş JPEG (CloudKit kaydı 1 MB'ı geçmesin diye ~700 KB altında)
    @NSManaged var imageData_: Data?
    @NSManaged var comments_: NSSet?

    // Tuval modunda konum
    @NSManaged var x: Double
    @NSManaged var y: Double
    @NSManaged var width: Double
    /// Tuvalde konumu belirlendi mi? Belge modunda oluşan bloklar false kalır ve
    /// tuval açıldığında otomatik dizilir.
    @NSManaged var isPlaced: Bool

    @NSManaged var page: Page?
    @NSManaged var parentUUID_: UUID?

    // Senkron meta verisi
    @NSManaged var zoneName_: String?
    @NSManaged var zoneOwner_: String?
    @NSManaged var ckSystemFields_: Data?
    @NSManaged var modifiedAt_: Date?

    var uuid: UUID { uuid_ ?? UUID() }
    var text: String { get { text_ ?? "" } set { text_ = newValue } }
    var doneNote: String? { doneNote_ }
    var assigneeID: String? { assigneeID_ }
    var assigneeName: String? { assigneeName_ }
    var assignedByName: String? { assignedByName_ }
    var assignedByID: String? { assignedByID_ }
    var doneByName: String? { doneByName_ }
    var isAssignedToMe: Bool { assigneeID_ != nil && assigneeID_ == Persistence.shared.me.id }
    var dueDate: Date? { get { dueDate_ } set { dueDate_ = newValue; page?.touch() } }
    var comments: [Comment] {
        ((comments_ as? Set<Comment>) ?? []).filter { !$0.isDeleted }.sorted { $0.createdAt < $1.createdAt }
    }

    var kind: BlockKind {
        get { BlockKind(rawValue: kind_ ?? "") ?? .text }
        set { kind_ = newValue.rawValue }
    }

    var doneBy: Completer? {
        get { doneBy_.flatMap(Completer.init(rawValue:)) }
        set { doneBy_ = newValue?.rawValue }
    }

    override func awakeFromInsert() {
        super.awakeFromInsert()
        uuid_ = UUID()
        createdAt_ = .now
        x = 60; y = 60; width = 280
    }

    func setDone(_ done: Bool, by completer: Completer, note: String? = nil) {
        isDone = done
        doneBy = done ? completer : nil
        doneAt_ = done ? .now : nil
        doneNote_ = done ? note : nil
        let myName = Persistence.shared.myDisplayName(for: page?.notebook)
        doneByID_ = done ? Persistence.shared.me.id : nil
        doneByName_ = done ? (completer == .ai ? "Yapay zeka" + (myName.map { " (\($0))" } ?? "") : myName) : nil
        page?.touch()
    }

    func assign(to person: Person?) {
        assigneeID_ = person?.id
        assigneeName_ = person?.name
        let me = Persistence.shared.me
        assignedByID_ = person == nil ? nil : me.id
        assignedByName_ = person == nil ? nil : Persistence.shared.myDisplayName(for: page?.notebook)
        assignedAt_ = person == nil ? nil : .now
        page?.touch()
    }

    func place(x: Double, y: Double) {
        self.x = max(0, x)
        self.y = max(0, y)
        isPlaced = true
    }

    /// Tuval kartının yaklaşık yüksekliği (otomatik dizilim için).
    var estimatedCanvasHeight: Double {
        if kind == .divider { return 30 }
        let charWidth: Double = kind.isHeading ? 14 : 8.5
        let perLine = max(8, (width - 24) / charWidth)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int((Double($1.count) / perLine).rounded(.up))) }
        let lineHeight: Double = kind.isHeading ? 30 : 22
        if kind == .image { return 14 + 10 + width * 0.66 + (text.isEmpty ? 0 : 24) }
        let chips: Double = (assigneeID != nil || dueDate != nil || !comments.isEmpty) ? 22 : 0
        return 14 + 10 + Double(lines) * lineHeight + (kind.isHeading ? 12 : 4) + chips
    }
}

// MARK: - Comment

/// Bir bloğa (genelde göreve) yazılan yorum. Bloğun CloudKit bölgesinde durur, onunla senkronlanır.
@objc(Comment)
final class Comment: NSManagedObject, Identifiable {
    var id: UUID { uuid }

    @NSManaged var uuid_: UUID?
    @NSManaged var text_: String?
    @NSManaged var authorID_: String?
    @NSManaged var authorName_: String?
    /// Bahsedilen kişilerin kimlikleri, virgülle ayrılmış
    @NSManaged var mentionIDs_: String?
    @NSManaged var createdAt_: Date?
    @NSManaged var block: Block?
    @NSManaged var parentUUID_: UUID?

    @NSManaged var zoneName_: String?
    @NSManaged var zoneOwner_: String?
    @NSManaged var ckSystemFields_: Data?
    @NSManaged var modifiedAt_: Date?

    var uuid: UUID { uuid_ ?? UUID() }
    var text: String { text_ ?? "" }
    var authorName: String { authorName_ ?? "Biri" }
    var createdAt: Date { createdAt_ ?? .distantPast }
    var mentionIDs: [String] { (mentionIDs_ ?? "").split(separator: ",").map(String.init) }
    var isMine: Bool { authorID_ == Persistence.shared.me.id }

    override func awakeFromInsert() {
        super.awakeFromInsert()
        uuid_ = UUID()
        createdAt_ = .now
    }

    /// `people` içinden metinde "@İsim" ile geçenler bahsedilmiş sayılır.
    @discardableResult
    static func add(_ text: String, to block: Block, people: [Person], byAI: Bool = false,
                    in context: NSManagedObjectContext) -> Comment {
        let comment = Comment(entity: DataModel.entity("Comment"), insertInto: context)
        comment.text_ = text
        let me = Persistence.shared.me
        let myName = Persistence.shared.myDisplayName(for: block.page?.notebook)
        comment.authorID_ = me.id
        comment.authorName_ = byAI ? "Yapay zeka" + (myName.map { " (\($0))" } ?? "") : (myName ?? "Ben")
        let lowered = text.lowercased()
        comment.mentionIDs_ = people.filter { !$0.isMe && lowered.contains("@" + $0.name.lowercased()) }
            .map(\.id).joined(separator: ",")
        comment.zoneName_ = block.zoneName_
        comment.zoneOwner_ = block.zoneOwner_
        comment.block = block
        block.page?.touch()
        return comment
    }
}

/// Paylaşılan bir defterin katılımcısı.
struct Person: Hashable, Identifiable {
    var id: String      // CloudKit userRecordID.recordName
    var name: String
    var isMe: Bool = false
}

// MARK: - Senkron için nesne ağacı

/// Senkronlanan varlıklar ve ebeveynleri (iCloud ve yakın cihaz senkronu ortak kullanır).
enum EntityGraph {
    static let entities = ["Notebook", "Page", "Block", "Comment"]
    /// Ebeveyn önce uygulansın diye sıra
    static let order: [String: Int] = ["Notebook": 0, "Page": 1, "Block": 2, "Comment": 3]
    /// Varlık → (ebeveyn varlık, ilişki adı)
    static let parent: [String: (entity: String, key: String)] = [
        "Page": ("Notebook", "notebook"), "Block": ("Page", "page"), "Comment": ("Block", "block"),
    ]

    static func parentObject(of object: NSManagedObject) -> NSManagedObject? {
        guard let name = object.entity.name, let link = parent[name] else { return nil }
        return object.value(forKey: link.key) as? NSManagedObject
    }
}

// MARK: - Programatik model

/// Model kodda tanımlı (bundle'da .momd yok), bu yüzden Core Data eski sürümü kendisi bulamaz.
/// Her sürüm burada yeniden üretilebilir; `Persistence` açılışta depoyu adım adım güncel sürüme taşır.
///  - v0: NSPersistentCloudKitContainer dönemi (senkron alanları yok)
///  - v1: CKSyncEngine + atama / tamamlayan
///  - v2: görsel, çizim, yorumlar, son düzenleyen, atanma zamanı
enum DataModel {
    static let currentVersion = 2

    /// Süreç başına tek model örneği olmalı (aynı sınıflarla birden fazla model Core Data'yı karıştırır).
    static let shared: NSManagedObjectModel = make(version: currentVersion)

    /// Eski sürümleri okumak/taşımak için: sınıflar genel NSManagedObject (asıl modelle sınıf çakışmasın).
    static func make(legacy: Bool) -> NSManagedObjectModel {
        legacy ? make(version: 0, generic: true) : shared
    }

    static func make(version: Int, generic: Bool = false) -> NSManagedObjectModel {
        func attr(_ name: String, _ type: NSAttributeType, _ defaultValue: Any? = nil,
                  external: Bool = false) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = true
            a.defaultValue = defaultValue
            a.allowsExternalBinaryDataStorage = external
            return a
        }
        func relation(_ name: String, to: NSEntityDescription, toMany: Bool,
                      delete: NSDeleteRule) -> NSRelationshipDescription {
            let r = NSRelationshipDescription()
            r.name = name
            r.destinationEntity = to
            r.isOptional = true
            r.minCount = 0
            r.maxCount = toMany ? 0 : 1
            r.deleteRule = delete
            return r
        }
        func entity(_ name: String) -> NSEntityDescription {
            let e = NSEntityDescription()
            e.name = name
            e.managedObjectClassName = generic ? NSStringFromClass(NSManagedObject.self) : name
            return e
        }
        let sync: [NSAttributeDescription] = version >= 1 ? [
            attr("zoneName_", .stringAttributeType), attr("zoneOwner_", .stringAttributeType),
            attr("ckSystemFields_", .binaryDataAttributeType), attr("modifiedAt_", .dateAttributeType),
        ] : []

        let notebook = entity("Notebook")
        let page = entity("Page")
        let block = entity("Block")

        let nbPages = relation("pages_", to: page, toMany: true, delete: .cascadeDeleteRule)
        let pageNotebook = relation("notebook", to: notebook, toMany: false, delete: .nullifyDeleteRule)
        nbPages.inverseRelationship = pageNotebook
        pageNotebook.inverseRelationship = nbPages

        let pageBlocks = relation("blocks_", to: block, toMany: true, delete: .cascadeDeleteRule)
        let blockPage = relation("page", to: page, toMany: false, delete: .nullifyDeleteRule)
        pageBlocks.inverseRelationship = blockPage
        blockPage.inverseRelationship = pageBlocks

        notebook.properties = [
            attr("uuid_", .UUIDAttributeType), attr("name_", .stringAttributeType),
            attr("icon_", .stringAttributeType), attr("colorHex_", .stringAttributeType),
            attr("sortIndex", .integer64AttributeType, 0), attr("createdAt_", .dateAttributeType),
            nbPages,
        ] + sync

        page.properties = [
            attr("uuid_", .UUIDAttributeType), attr("title_", .stringAttributeType),
            attr("layout_", .stringAttributeType), attr("isPinned", .booleanAttributeType, false),
            attr("createdAt_", .dateAttributeType), attr("updatedAt_", .dateAttributeType),
            pageNotebook, pageBlocks,
        ] + sync
        if version >= 1 { page.properties.append(attr("parentUUID_", .UUIDAttributeType)) }
        if version >= 2 {
            page.properties += [attr("drawing_", .binaryDataAttributeType, external: true),
                                attr("authorName_", .stringAttributeType), attr("lastEditorName_", .stringAttributeType)]
        }

        block.properties = [
            attr("uuid_", .UUIDAttributeType), attr("kind_", .stringAttributeType),
            attr("text_", .stringAttributeType), attr("order", .doubleAttributeType, 0.0),
            attr("indent", .integer64AttributeType, 0), attr("createdAt_", .dateAttributeType),
            attr("authorName_", .stringAttributeType),
            attr("isDone", .booleanAttributeType, false), attr("doneBy_", .stringAttributeType),
            attr("doneAt_", .dateAttributeType), attr("doneNote_", .stringAttributeType),
            attr("assigneeID_", .stringAttributeType), attr("assigneeName_", .stringAttributeType),
            attr("assignedByID_", .stringAttributeType), attr("assignedByName_", .stringAttributeType),
            attr("dueDate_", .dateAttributeType),
            attr("x", .doubleAttributeType, 60.0), attr("y", .doubleAttributeType, 60.0),
            attr("width", .doubleAttributeType, 280.0), attr("isPlaced", .booleanAttributeType, false),
            blockPage,
        ] + sync
        if version >= 1 {
            block.properties += [attr("parentUUID_", .UUIDAttributeType),
                                 attr("doneByID_", .stringAttributeType), attr("doneByName_", .stringAttributeType)]
        }

        var entities = [notebook, page, block]
        if version >= 2 {
            block.properties += [attr("assignedAt_", .dateAttributeType),
                                 attr("imageData_", .binaryDataAttributeType, external: true)]

            let comment = entity("Comment")
            let blockComments = relation("comments_", to: comment, toMany: true, delete: .cascadeDeleteRule)
            let commentBlock = relation("block", to: block, toMany: false, delete: .nullifyDeleteRule)
            blockComments.inverseRelationship = commentBlock
            commentBlock.inverseRelationship = blockComments
            block.properties.append(blockComments)
            comment.properties = [
                attr("uuid_", .UUIDAttributeType), attr("text_", .stringAttributeType),
                attr("authorID_", .stringAttributeType), attr("authorName_", .stringAttributeType),
                attr("mentionIDs_", .stringAttributeType), attr("createdAt_", .dateAttributeType),
                attr("parentUUID_", .UUIDAttributeType), commentBlock,
            ] + sync
            entities.append(comment)
        }

        let model = NSManagedObjectModel()
        model.entities = entities
        return model
    }
}
