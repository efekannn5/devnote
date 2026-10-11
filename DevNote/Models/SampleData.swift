import Foundation
import CoreData

enum SampleData {
    static func seedIfNeeded(_ context: NSManagedObjectContext) {
        let count = (try? context.count(for: Notebook.fetchAll())) ?? 0
        guard count == 0, !UserDefaults.standard.bool(forKey: "didSeedSampleData") else { return }
        UserDefaults.standard.set(true, forKey: "didSeedSampleData")

        let work = Notebook.create(name: "Proje", icon: "hammer.fill", colorHex: "#0A84FF", sortIndex: 0, in: context)
        let personal = Notebook.create(name: "Kişisel", icon: "heart.fill", colorHex: "#FF375F", sortIndex: 1, in: context)
        let ideas = Notebook.create(name: "Fikirler", icon: "lightbulb.fill", colorHex: "#FFD60A", sortIndex: 2, in: context)

        let sprint = Page.create(title: "Sprint 1 — Yapılacaklar", notebook: work, in: context)
        sprint.isPinned = true
        sprint.addBlock(.heading, text: "Bu hafta", in: context)
        sprint.addBlock(.text, text: "Yapay zeka bu listeyi MCP üzerinden okuyup tamamladıklarını işaretleyebilir.", in: context)
        sprint.addBlock(.checklist, text: "Giriş ekranındaki çökme hatasını düzelt", in: context)
        sprint.addBlock(.checklist, text: "API isteklerine zaman aşımı ekle", in: context)
        sprint.addBlock(.checklist, text: "README'yi güncelle", in: context)
            .setDone(true, by: .ai, note: "Kurulum ve MCP bölümleri eklendi.")
        sprint.addBlock(.quote, text: "Önce Mac, sonra iPhone, sonra Windows & Android.", in: context)

        let board = Page.create(title: "Mimari taslak", notebook: work, layout: .canvas, in: context)
        let positions: [(BlockKind, String, Double, Double)] = [
            (.heading, "İstemciler", 40, 20),
            (.bullet, "macOS (SwiftUI)", 40, 80),
            (.bullet, "iOS (SwiftUI)", 40, 120),
            (.heading, "Senkron", 420, 20),
            (.text, "iCloud / CloudKit — Mac ↔ iPhone, paylaşılan defterler", 420, 80),
            (.heading, "Yapay Zeka", 40, 200),
            (.code, "http://127.0.0.1:7337/mcp", 40, 260),
            (.checklist, "Windows / Android için sunucu", 420, 200),
        ]
        for (kind, text, x, y) in positions {
            board.addBlock(kind, text: text, in: context).place(x: x, y: y)
        }

        let groceries = Page.create(title: "Market", notebook: personal, in: context)
        for item in ["Süt", "Kahve", "Avokado"] {
            groceries.addBlock(.checklist, text: item, in: context)
        }

        let idea = Page.create(title: "Not uygulaması özellikleri", notebook: ideas, in: context)
        for item in ["El yazısı / Apple Pencil", "Sesli not + transkript", "Paylaşılan defterler", "Etiketler & akıllı klasörler"] {
            idea.addBlock(.bullet, text: item, in: context)
        }

        try? context.save()
    }
}
