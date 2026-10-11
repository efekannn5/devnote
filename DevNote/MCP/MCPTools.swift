#if os(macOS)
import Foundation
import CoreData

/// MCP JSON-RPC katmanı: initialize, ping, tools/list, tools/call.
@MainActor
final class MCPTools {
    private let context: NSManagedObjectContext
    private let onActivity: (String) -> Void

    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    init(context: NSManagedObjectContext, onActivity: @escaping (String) -> Void) {
        self.context = context
        self.onActivity = onActivity
    }

    // MARK: - JSON-RPC

    func handle(_ message: Any) -> Any? {
        if let batch = message as? [Any] {
            let replies = batch.compactMap(handleOne)
            return replies.isEmpty ? nil : replies
        }
        return handleOne(message)
    }

    private func handleOne(_ message: Any) -> Any? {
        guard let msg = message as? [String: Any] else {
            return Self.rpcError(id: nil, code: -32600, message: "Invalid Request")
        }
        guard let method = msg["method"] as? String else { return nil } // istemciden gelen yanıt
        guard let id = msg["id"] else { return nil }                      // bildirim (notification)
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            let client = (params["clientInfo"] as? [String: Any])?["name"] as? String ?? "istemci"
            onActivity("\(client) bağlandı")
            return Self.rpcResult(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "devnote", "title": "DevNote", "version": "0.1.0"],
                "instructions": Self.instructions,
            ])
        case "ping":
            return Self.rpcResult(id: id, [:])
        case "tools/list":
            return Self.rpcResult(id: id, ["tools": Self.toolDefinitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try call(name, args)
                Persistence.shared.save()
                return Self.rpcResult(id: id, ["content": [["type": "text", "text": text]], "isError": false])
            } catch {
                ErrorReporter.shared.report(message: "\(name): \(error)", area: "MCP aracı", silent: true)
                return Self.rpcResult(id: id, ["content": [["type": "text", "text": "\(error)"]], "isError": true])
            }
        default:
            return Self.rpcError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static func rpcResult(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func rpcError(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    // MARK: - Araçlar

    struct ToolError: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    private func call(_ name: String, _ a: [String: Any]) throws -> String {
        switch name {
        case "list_notebooks":
            let nbs = try context.fetch(Notebook.fetchAll())
            if nbs.isEmpty { return "Hiç defter yok." }
            return nbs.map { nb in
                let pages = nb.pages
                let open = pages.reduce(0) { $0 + $1.openTaskCount }
                let shared = Persistence.shared.isShared(nb) ? ", paylaşılan" : ""
                return "- \(nb.name) (id: \(short(nb.uuid)), \(pages.count) sayfa, \(open) açık görev\(shared))"
            }.joined(separator: "\n")

        case "list_pages":
            var pages = try allPages()
            if let nbArg = a["notebook"] as? String {
                let nb = try notebook(nbArg)
                pages = pages.filter { $0.notebook == nb }
            }
            if pages.isEmpty { return "Sayfa bulunamadı." }
            return pages.map { p in
                let t = p.tasks
                return "- \"\(title(p))\" (page_id: \(short(p.uuid)), defter: \(p.notebook?.name ?? "-"), görevler: \(t.count - p.openTaskCount)/\(t.count))"
            }.joined(separator: "\n")

        case "read_page":
            return render(try page(try string(a, "page")))

        case "list_open_tasks":
            var pages = try allPages()
            if let nbArg = a["notebook"] as? String {
                let nb = try notebook(nbArg)
                pages = pages.filter { $0.notebook == nb }
            }
            if let pageArg = a["page"] as? String {
                let p = try page(pageArg)
                pages = [p]
            }
            var assigneeID: String?
            if let who = a["assignee"] as? String, !who.isEmpty {
                guard let target = try person(who, in: nil) else { throw ToolError("Kişi bulunamadı: \(who)") }
                assigneeID = target.id
            }
            let lines = pages.flatMap { p in
                p.tasks.filter { !$0.isDone && (assigneeID == nil || $0.assigneeID == assigneeID) }.map {
                    "- [ ] \($0.text)  (task_id: \(short($0.uuid)), sayfa: \"\(title(p))\", defter: \(p.notebook?.name ?? "-")\(meta($0)))"
                }
            }
            return lines.isEmpty ? "Açık görev yok. 🎉" : lines.joined(separator: "\n")

        case "list_people":
            let nbs: [Notebook]
            if let nbArg = a["notebook"] as? String {
                nbs = [try notebook(nbArg)]
            } else {
                nbs = try context.fetch(Notebook.fetchAll()).filter { Persistence.shared.isShared($0) }
            }
            if nbs.isEmpty { return "Paylaşılan defter yok. Görev atamak için önce defteri uygulamadan paylaş." }
            return nbs.map { nb in
                let members = Persistence.shared.teamMembers(for: nb)
                let open = nb.pages.flatMap(\.tasks).filter { !$0.isDone }
                let lines = members.map { m in
                    let count = open.filter { $0.assigneeID == m.person.id }.count
                    let flags = [m.isOwner ? "sahip" : nil, m.canEdit ? nil : "salt okunur", m.accepted ? nil : "davet bekliyor"]
                        .compactMap { $0 }.joined(separator: ", ")
                    return "  - \(m.person.isMe ? "Ben (kullanıcı)" : m.person.name)\(flags.isEmpty ? "" : " [\(flags)]") — \(count) açık görev"
                }
                return (["\(nb.name):"] + lines).joined(separator: "\n")
            }.joined(separator: "\n")

        case "assign_task":
            let task = try block(try string(a, "task_id"))
            guard task.kind == .checklist else { throw ToolError("Bu blok bir yapılacak maddesi değil.") }
            guard Persistence.shared.canEdit(task) else { throw ToolError("Bu defterde düzenleme yetkin yok.") }
            let who = a["person"] as? String ?? ""
            if who.isEmpty {
                task.assign(to: nil)
                return "Atama kaldırıldı: \(task.text)"
            }
            guard let target = try person(who, in: task.page?.notebook) else {
                throw ToolError("Kişi bulunamadı: \(who)")
            }
            task.assign(to: target)
            TaskActions.changed()
            onActivity("→ \(target.name): \(task.text)")
            return "\(target.isMe ? "Kullanıcıya" : target.name + " kişisine") atandı: \(task.text)"

        case "set_due_date":
            let task = try block(try string(a, "task_id"))
            let raw = a["due"] as? String ?? ""
            if raw.isEmpty {
                task.dueDate = nil
            } else {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]
                guard let date = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw + ":00Z") else {
                    throw ToolError("Tarih ISO 8601 olmalı, ör. 2026-10-12T17:00:00+03:00")
                }
                task.dueDate = date
            }
            TaskActions.changed()
            return task.dueDate.map { "Son tarih: \($0.formatted(date: .abbreviated, time: .shortened)) — \(task.text)" }
                ?? "Son tarih kaldırıldı: \(task.text)"

        case "list_comments":
            let task = try block(try string(a, "task_id"))
            if task.comments.isEmpty { return "Yorum yok: \(task.text)" }
            return (["Yorumlar — \(task.text):"] + task.comments.map {
                "- \($0.authorName) (\($0.createdAt.formatted(date: .abbreviated, time: .shortened))): \($0.text)"
            }).joined(separator: "\n")

        case "add_comment":
            let task = try block(try string(a, "task_id"))
            guard Persistence.shared.canEdit(task) else { throw ToolError("Bu defterde düzenleme yetkin yok.") }
            let text = try string(a, "text").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ToolError("Yorum boş olamaz.") }
            Comment.add(text, to: task, people: Persistence.shared.participants(for: task.page?.notebook),
                        byAI: true, in: context)
            TaskActions.changed()
            onActivity("💬 \(task.text)")
            return "Yorum eklendi: \(task.text)"

        case "complete_task":
            let task = try block(try string(a, "task_id"))
            guard task.kind == .checklist else { throw ToolError("Bu blok bir yapılacak maddesi değil.") }
            if task.isDone { return "Zaten tamamlanmış: \(task.text)" }
            task.setDone(true, by: .ai, note: a["note"] as? String)
            TaskActions.changed()
            onActivity("✓ \(task.text)")
            return "Tamamlandı olarak işaretlendi: \(task.text)"

        case "reopen_task":
            let task = try block(try string(a, "task_id"))
            guard task.kind == .checklist else { throw ToolError("Bu blok bir yapılacak maddesi değil.") }
            task.setDone(false, by: .ai)
            onActivity("↺ \(task.text)")
            return "Yeniden açıldı: \(task.text)"

        case "add_task":
            let p = try page(try string(a, "page"))
            let after = try (a["after_task_id"] as? String).map(block)
            let task = p.addBlock(.checklist, text: try string(a, "text"), after: after, in: context)
            onActivity("+ \(task.text)")
            return "Eklendi (task_id: \(short(task.uuid))): \(task.text)"

        case "create_page":
            let nbName = try string(a, "notebook")
            let nb = (try? notebook(nbName)) ?? {
                let count = (try? context.count(for: Notebook.fetchAll())) ?? 0
                return Notebook.create(name: nbName, sortIndex: count, in: context)
            }()
            let layout = PageLayout(rawValue: a["layout"] as? String ?? "") ?? .document
            let p = Page.create(title: try string(a, "title"), notebook: nb, layout: layout, in: context)
            insertMarkdown(a["content"] as? String ?? "", into: p)
            onActivity("Yeni sayfa: \(p.title)")
            return "Oluşturuldu (page_id: \(short(p.uuid))).\n\n" + render(p)

        case "append_to_page":
            let p = try page(try string(a, "page"))
            insertMarkdown(try string(a, "content"), into: p)
            onActivity("Not eklendi: \(title(p))")
            return render(p)

        case "search":
            let q = try string(a, "query")
            let hits = try allPages().filter { p in
                p.title.localizedCaseInsensitiveContains(q) || p.sortedBlocks.contains { $0.text.localizedCaseInsensitiveContains(q) }
            }
            if hits.isEmpty { return "Sonuç yok." }
            return hits.map { p in
                let matches = p.sortedBlocks.filter { $0.text.localizedCaseInsensitiveContains(q) }.prefix(3)
                    .map { "    · \($0.text) (id: \(short($0.uuid)))" }
                return (["- \"\(title(p))\" (page_id: \(short(p.uuid)))"] + matches).joined(separator: "\n")
            }.joined(separator: "\n")

        default:
            throw ToolError("Bilinmeyen araç: \(name)")
        }
    }

    // MARK: - Yardımcılar

    private func short(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }

    /// Atama ve son tarih bilgisi (varsa).
    private func meta(_ b: Block) -> String {
        var parts: [String] = []
        if let name = b.assigneeName { parts.append("atanan: \(name)") }
        if let due = b.dueDate { parts.append("son tarih: \(due.formatted(date: .abbreviated, time: .shortened))") }
        return parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")
    }
    private func title(_ p: Page) -> String { p.title.isEmpty ? "Başlıksız" : p.title }

    /// "me"/"ben" ya da katılımcı adı (büyük/küçük harf duyarsız, kısmi eşleşme). `notebook` nil ise tüm paylaşılan defterlerde arar.
    private func person(_ key: String, in notebook: Notebook?) throws -> Person? {
        let me = Persistence.shared.me
        if ["me", "ben", "bana", "kullanıcı", "user"].contains(key.lowercased()) { return me }
        let notebooks = try notebook.map { [$0] } ?? context.fetch(Notebook.fetchAll())
        // Atanan kişiler paylaşım listesi önbellekte olmasa da bulunabilsin
        let known = notebooks.flatMap(\.pages).flatMap(\.tasks).compactMap { b in
            b.assigneeID.map { Person(id: $0, name: b.assigneeName ?? $0, isMe: $0 == me.id) }
        }
        let people = notebooks.flatMap { Persistence.shared.teamMembers(for: $0) }.filter(\.accepted).map(\.person) + known
        let matches = Dictionary(grouping: people.filter { $0.name.localizedCaseInsensitiveContains(key) }, by: \.id)
        if matches.count > 1 { throw ToolError("Birden çok kişi eşleşti: \(matches.values.compactMap { $0.first?.name }.joined(separator: ", "))") }
        return matches.values.first?.first
    }

    private func string(_ a: [String: Any], _ key: String) throws -> String {
        guard let v = a[key] as? String, !v.isEmpty else { throw ToolError("'\(key)' parametresi gerekli.") }
        return v
    }

    private func allPages() throws -> [Page] {
        try context.fetch(Page.fetchAll())
    }

    private func unique<T>(_ items: [T], _ what: String, _ key: String) throws -> T {
        if items.count == 1 { return items[0] }
        throw ToolError(items.isEmpty ? "\(what) bulunamadı: \(key)" : "\(what) belirsiz, daha uzun bir id ver: \(key)")
    }

    private func matchesID(_ id: UUID, _ key: String) -> Bool {
        key.count >= 4 && id.uuidString.lowercased().hasPrefix(key.lowercased())
    }

    private func block(_ key: String) throws -> Block {
        let all = try context.fetch(Block.fetchAll())
        return try unique(all.filter { matchesID($0.uuid, key) }, "Görev", key)
    }

    private func page(_ key: String) throws -> Page {
        let all = try allPages()
        let byID = all.filter { matchesID($0.uuid, key) }
        if !byID.isEmpty { return try unique(byID, "Sayfa", key) }
        return try unique(all.filter { $0.title.caseInsensitiveCompare(key) == .orderedSame }, "Sayfa", key)
    }

    private func notebook(_ key: String) throws -> Notebook {
        let all = try context.fetch(Notebook.fetchAll())
        let byID = all.filter { matchesID($0.uuid, key) }
        if !byID.isEmpty { return try unique(byID, "Defter", key) }
        return try unique(all.filter { $0.name.caseInsensitiveCompare(key) == .orderedSame }, "Defter", key)
    }

    /// Sayfayı yapay zekanın kolay okuyacağı Markdown'a çevirir; her satırda blok id'si var.
    private func render(_ p: Page) -> String {
        var out = ["# \(title(p))",
                   "page_id: \(short(p.uuid)) · defter: \(p.notebook?.name ?? "-") · görünüm: \(p.layout.title)", ""]
        for b in p.sortedBlocks where !b.text.isEmpty || b.kind == .image || b.kind == .divider {
            let pad = String(repeating: "  ", count: Int(b.indent))
            let number = b.kind == .numbered ? (p.listNumber(of: b) ?? 1) : 1
            let line: String = switch b.kind {
            case .heading: "## \(b.text)"
            case .heading2: "### \(b.text)"
            case .heading3: "#### \(b.text)"
            case .checklist:
                "- [\(b.isDone ? "x" : " ")] \(b.text)" + (b.doneBy == .ai ? " _(AI: \(b.doneNote ?? "tamamladı"))_" : "")
                    + (meta(b).isEmpty ? "" : " _(\(meta(b).dropFirst(2)))_")
            case .bullet: "- \(b.text)"
            case .numbered: "\(number). \(b.text)"
            case .quote: "> \(b.text)"
            case .code: "```\n\(b.text)\n```"
            case .divider: "---"
            case .text: b.text
            case .image: "![\(b.text.isEmpty ? "görsel" : b.text)](görsel)"
            }
            out.append("\(pad)\(line)  <!-- id: \(short(b.uuid)) -->")
            for c in b.comments {
                out.append("\(pad)    > 💬 \(c.authorName) (\(c.createdAt.formatted(date: .abbreviated, time: .shortened))): \(c.text)")
            }
        }
        return out.joined(separator: "\n")
    }

    /// Markdown → bloklar (uygulamadaki yapıştırma ile aynı dönüştürücü)
    private func insertMarkdown(_ md: String, into p: Page) {
        for item in MarkdownBlocks.parse(md) {
            let b = p.addBlock(item.kind, text: item.text, in: context)
            b.indent = Int64(item.indent)
            if item.isDone { b.setDone(true, by: .ai) }
        }
    }

    // MARK: - Tanımlar

    static let instructions = """
    DevNote kullanıcının not uygulamasıdır. Sayfalardaki yapılacak (checklist) maddeleri \
    kullanıcının senden beklediği işlerdir. Akış: list_open_tasks ile açık görevleri gör, \
    işi gerçekten yap ve doğrula, sonra complete_task ile kısa bir açıklama (note) bırakarak işaretle. \
    Doğrulamadığın bir maddeyi asla tamamlandı olarak işaretleme. id'ler 8 karakterlik kısa id olarak verilir.
    Ekip: paylaşılan defterlerde görevler kişilere atanır. Kullanıcının kendi işleri için     list_open_tasks(assignee: "me") kullan; başkasına atanmış görevi kullanıcı açıkça istemedikçe tamamlama.     Kişileri list_people ile gör, assign_task ve set_due_date ile ata ve süre ver.     Görevin yorumlarını list_comments ile oku; ilerleme ya da soru için add_comment kullan.     Satır içi biçim Markdown: **kalın**, *italik*, ~~üstü çizili~~, `kod`, [bağlantı](url), \
    ^[vurgulu](highlight: '#FFD60A'), ^[renkli](color: '#FF453A'), ^[altı çizili](underline: true), ^[büyük](size: 24).
    """

    static let toolDefinitions: [[String: Any]] = [
        tool("list_notebooks", "Tüm defterleri (gruplar) listeler.", [:], readOnly: true),
        tool("list_pages", "Sayfaları listeler; isteğe bağlı olarak bir deftere göre filtreler.",
             ["notebook": prop("Defter adı veya id'si")], readOnly: true),
        tool("read_page", "Bir sayfanın tüm içeriğini Markdown olarak (blok id'leriyle) döndürür.",
             ["page": prop("Sayfa id'si veya tam başlığı")], required: ["page"], readOnly: true),
        tool("list_open_tasks", "Tamamlanmamış yapılacak maddelerini task_id'leriyle, atanan kişi ve son tarihle listeler.",
             ["notebook": prop("Defter adı veya id'si (opsiyonel)"), "page": prop("Sayfa id'si veya başlığı (opsiyonel)"),
              "assignee": prop("Yalnızca bu kişiye atananlar: \"me\" (kullanıcı) ya da kişi adı (opsiyonel)")],
             readOnly: true),
        tool("list_people", "Paylaşılan defterlerdeki ekip üyelerini, rollerini ve açık görev sayılarını listeler.",
             ["notebook": prop("Defter adı veya id'si (opsiyonel)")], readOnly: true),
        tool("assign_task", "Görevi bir ekip üyesine atar (kişiye bildirim gider). Boş person atamayı kaldırır.",
             ["task_id": prop("Görev id'si"), "person": prop("\"me\" ya da list_people'daki kişi adı; boş = atamayı kaldır")],
             required: ["task_id"]),
        tool("set_due_date", "Göreve son tarih / hatırlatma koyar (atanan kişiye o saatte bildirim gider). Boş due kaldırır.",
             ["task_id": prop("Görev id'si"), "due": prop("ISO 8601 tarih, ör. 2026-10-12T17:00:00+03:00; boş = kaldır")],
             required: ["task_id"]),
        tool("list_comments", "Bir görevin (ya da bloğun) yorumlarını yazar ve zamanıyla listeler.",
             ["task_id": prop("Görev / blok id'si")], required: ["task_id"], readOnly: true),
        tool("add_comment", "Göreve yapay zeka adına yorum yazar (ilerleme, soru, sonuç). \"@İsim\" ile ekip üyesinden bahsedilirse ona bildirim gider.",
             ["task_id": prop("Görev / blok id'si"), "text": prop("Yorum metni (Markdown)")],
             required: ["task_id", "text"]),
        tool("complete_task", "Bir yapılacak maddesini yapay zeka tarafından tamamlandı olarak işaretler. Yalnızca işi doğruladıktan sonra çağır.",
             ["task_id": prop("Görev id'si"), "note": prop("Ne yapıldığına dair kısa açıklama; kullanıcıya gösterilir")],
             required: ["task_id"]),
        tool("reopen_task", "Tamamlanmış bir maddeyi yeniden açar.",
             ["task_id": prop("Görev id'si")], required: ["task_id"]),
        tool("add_task", "Bir sayfaya yeni yapılacak maddesi ekler.",
             ["page": prop("Sayfa id'si veya başlığı"), "text": prop("Madde metni"),
              "after_task_id": prop("Bu maddenin arkasına ekle (opsiyonel)")],
             required: ["page", "text"]),
        tool("create_page", "Yeni sayfa oluşturur. İçerik Markdown olabilir (- [ ] görev, # başlık, - madde, > alıntı, ``` kod).",
             ["notebook": prop("Defter adı (yoksa oluşturulur)"), "title": prop("Sayfa başlığı"),
              "content": prop("Markdown içerik"), "layout": ["type": "string", "enum": ["document", "canvas"]]],
             required: ["notebook", "title"]),
        tool("append_to_page", "Var olan bir sayfanın sonuna Markdown içerik ekler.",
             ["page": prop("Sayfa id'si veya başlığı"), "content": prop("Markdown içerik")],
             required: ["page", "content"]),
        tool("search", "Tüm notlarda metin araması yapar.",
             ["query": prop("Aranacak metin")], required: ["query"], readOnly: true),
    ]

    private static func prop(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func tool(_ name: String, _ description: String, _ props: [String: Any],
                             required: [String] = [], readOnly: Bool = false) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": props, "required": required],
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": false],
        ]
    }
}
#endif
