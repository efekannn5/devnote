import XCTest
import UIKit

/// Simülatörde elle dokunma gerektiren adımlar (izin uyarıları, ana ekran, Dynamic Island) için yardımcı akışlar.
///   TEST_RUNNER_DEMO=assign xcodebuild test-without-building -only-testing:DevNoteUITests/SimulatorFlowTests/testDemo ...
/// Ekran görüntüleri /tmp/devnote-ui-*.png olarak yazılır.
final class SimulatorFlowTests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let app = XCUIApplication(bundleIdentifier: "com.efekan.devnote")

    func testAllowNotifications() {
        app.activate()
        tapSystemButton(["İzin Ver", "Allow"], timeout: 5)
    }

    /// Demo olayını tetikler, banner'ı, ana ekrandaki Dynamic Island'ı ve genişletilmiş halini çeker.
    func testDemo() {
        let demo = ProcessInfo.processInfo.environment["DEMO"] ?? "assign"
        app.activate()
        sleep(1)
        XCUIDevice.shared.system.open(URL(string: "devnote://debug/\(demo)")!)
        tapSystemButton(["Aç", "Open"], timeout: 3)
        sleep(2)
        snapshot("1-banner")
        XCUIDevice.shared.press(.home)
        sleep(3)
        snapshot("2-home")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).press(forDuration: 1.0)
        sleep(1)
        snapshot("3-expanded")
    }

    /// Dynamic Island'daki "Tamamla" düğmesine bas (genişletilmiş haldeyken).
    func testCompleteFromIsland() {
        XCUIDevice.shared.press(.home)
        sleep(1)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).press(forDuration: 1.0)
        sleep(1)
        let button = springboard.buttons["Tamamla"]
        if button.waitForExistence(timeout: 3) { button.tap() }
        sleep(2)
        snapshot("4-completed")
    }

    /// Editör demo sayfasını aç, sonra yorumları göster.
    func testEditor() {
        app.activate()
        sleep(1)
        XCUIDevice.shared.system.open(URL(string: "devnote://debug/editor")!)
        tapSystemButton(["Aç", "Open"], timeout: 3)
        sleep(3)
        snapshot("e1-editor")
        let comments = app.buttons["Yorumlar"].firstMatch
        if comments.waitForExistence(timeout: 3) {
            comments.tap()
            sleep(2)
            snapshot("e2-comments")
        }
    }

    /// Tuval: tutamaçtan sürüklenen kart parmağı birebir izlemeli (bırakınca aynı mesafe kadar kaymış olmalı)
    func testCanvasDrag() {
        app.activate()
        sleep(1)
        XCUIDevice.shared.system.open(URL(string: "devnote://debug/editor-canvas")!)
        tapSystemButton(["Aç", "Open"], timeout: 3)
        sleep(3)
        snapshot("c1-canvas")
        // Ölçüm: sürüklenen kartın metni (tutamaç her sorguda farklı karta denk gelebiliyor)
        let title = app.descendants(matching: .any).matching(NSPredicate(format: "value == 'Sprint planı' OR label == 'Sprint planı'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        let before = title.frame
        // İlk kartın tutamacı başlığın hemen üstünde
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: before.minX + 140, dy: before.minY - 22))
        let end = start.withOffset(CGVector(dx: 60, dy: 180))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        let after = app.descendants(matching: .any).matching(NSPredicate(format: "value == 'Sprint planı' OR label == 'Sprint planı'")).firstMatch.frame
        snapshot("c2-dragged")
        print("DRAG dx=\(after.minX - before.minX) dy=\(after.minY - before.minY)")
        XCTAssertEqual(after.minX - before.minX, 60, accuracy: 6)
        XCTAssertEqual(after.minY - before.minY, 180, accuracy: 6)
    }

    /// Yorumda bahsedilme bildirimi + Ekip ekranındaki etkinlik akışı
    func testMentionAndActivity() {
        app.activate()
        sleep(1)
        XCUIDevice.shared.system.open(URL(string: "devnote://debug/mention")!)
        tapSystemButton(["Aç", "Open"], timeout: 3)
        sleep(3)
        snapshot("m1-mention-banner")
        XCUIDevice.shared.system.open(URL(string: "devnote://debug/editor")!)
        tapSystemButton(["Aç", "Open"], timeout: 3)
        sleep(3)
        app.buttons["Diğer"].firstMatch.tap()
        sleep(1)
        let team = app.buttons["Ekip ve Davet"].firstMatch
        XCTAssertTrue(team.waitForExistence(timeout: 3))
        team.tap()
        sleep(3)
        app.swipeUp()
        sleep(1)
        snapshot("m2-activity")
    }

    /// Ana ekrana "Görevlerim" widget'ını ekle, ✓ ile bir görevi uygulamayı açmadan tamamla
    func testHomeWidget() {
        app.activate()
        sleep(3)
        XCUIDevice.shared.press(.home)
        sleep(2)
        let complete = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tamamla'")).firstMatch
        if !complete.exists { addTasksWidget() }
        snapshot("w1-home")
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        complete.tap()
        sleep(5)
        snapshot("w2-completed")
    }

    private func addTasksWidget() {
        // Boş bir yere uzun bas → düzenleme modu
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).press(forDuration: 1.6)
        sleep(1)
        tapSystemButton(["Edit", "Düzenle"], timeout: 2)
        tapSystemButton(["Add Widget", "Widget Ekle", "Araç Takımı Ekle"], timeout: 3)
        sleep(2)
        tapSystemButton(["Sürdür", "Continue"], timeout: 2)   // klavye ipucu
        let search = springboard.searchFields.firstMatch
        if search.waitForExistence(timeout: 3) { search.tap(); search.typeText("DevNote") }
        sleep(2)
        tapSystemButton(["Sürdür", "Continue"], timeout: 1)
        snapshot("w0-gallery")
        let result = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'DevNote' AND elementType != %d", XCUIElement.ElementType.searchField.rawValue)).element(boundBy: 0)
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        result.tap()
        sleep(2)
        springboard.swipeLeft()   // orta boy
        sleep(1)
        snapshot("w0b-picker")
        let add = springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Ekle' OR label CONTAINS 'Add'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        print("ADD BUTTON: \(add.label)")
        add.tap()
        sleep(2)
        tapSystemButton(["Done", "Bitti"], timeout: 3)
        sleep(3)
    }

    /// Tuvalde parmakla çiz; çizim modundan çıkınca çizim yerinde kalmalı
    func testCanvasDrawing() {
        app.activate()
        sleep(1)
        XCUIDevice.shared.system.open(URL(string: "devnote://debug/editor-canvas")!)
        tapSystemButton(["Aç", "Open"], timeout: 3)
        sleep(3)
        let draw = app.buttons["Çiz"].firstMatch
        XCTAssertTrue(draw.waitForExistence(timeout: 3))
        draw.tap()
        sleep(2)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        // Yıldıza benzeyen bir zikzak
        let points: [(CGFloat, CGFloat)] = [(80, 560), (200, 470), (320, 560), (200, 650), (80, 560)]
        for (a, b) in zip(points, points.dropFirst()) {
            origin.withOffset(CGVector(dx: a.0, dy: a.1))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: b.0, dy: b.1)))
        }
        sleep(1)
        snapshot("d1-drawing")
        app.buttons["Çizimi bitir"].firstMatch.tap()
        sleep(2)
        snapshot("d2-done")
    }

    /// Zengin metin: seçili kelimeyi kalın + vurgulu yap; seçimsiz italik ile yazmaya devam et
    func testRichText() {
        app.activate()
        sleep(1)
        XCUIDevice.shared.system.open(URL(string: "devnote://debug/editor")!)
        tapSystemButton(["Aç", "Open"], timeout: 3)
        sleep(3)
        snapshot("r1-editor")
        let field = app.textViews.matching(NSPredicate(format: "value CONTAINS 'Müşteri'")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        sleep(1)
        field.doubleTap()
        sleep(1)
        app.buttons["Kalın"].firstMatch.tap()
        sleep(1)
        app.buttons["Vurgula"].firstMatch.tap()
        sleep(1)
        snapshot("r2-selected")
        // İmleci sona al, seçim yokken İtalik → yazılan italik olmalı
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        sleep(1)
        app.buttons["İtalik"].firstMatch.tap()
        app.typeText(" eğik")
        sleep(1)
        snapshot("r3-typing")
        // Başka bir kelime: büyük, kırmızı, altı çizili
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.5)).doubleTap()
        sleep(1)
        app.buttons["Altı Çizili"].firstMatch.tap()
        sleep(1)
        app.buttons["Yazı boyutu"].firstMatch.tap()
        app.buttons["24 px"].firstMatch.tap()
        sleep(1)
        app.buttons["Yazı rengi"].firstMatch.tap()
        app.buttons["Kırmızı"].firstMatch.tap()
        sleep(1)
        snapshot("r3b-size-color")
        app.buttons["Klavyeyi kapat"].firstMatch.tap()
        sleep(2)
        snapshot("r4-done")
    }

    /// Notion tarzı bloklar: Markdown kısayolu, Enter ile bölme, "/" menüsü, liste devamı, Markdown yapıştırma
    func testNotionBlocks() {
        app.activate()
        sleep(1)
        XCUIDevice.shared.system.open(URL(string: "devnote://debug/blocks")!)
        tapSystemButton(["Aç", "Open"], timeout: 3)
        sleep(3)
        let first = app.textViews.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        first.tap()
        sleep(1)
        type("# Proje planı\nGiriş paragrafı\n/mad")
        sleep(1)
        snapshot("n1-slash")
        let bullet = app.buttons["Madde işaretli liste"].firstMatch
        XCTAssertTrue(bullet.waitForExistence(timeout: 3))
        bullet.tap()
        sleep(1)
        // Her Enter'dan sonra odak yeni satıra geçsin (gerçek yazım hızı)
        type("bir\niki\n\n[] görev\n")
        sleep(1)
        snapshot("n2-blocks")
        // Markdown yapıştır: bloklara bölünmeli
        UIPasteboard.general.string = "## Notlar\n- a maddesi\n- b maddesi\n1. ilk\n2. ikinci\n> alıntı\n---\nson satır **kalın**"
        app.typeText("\n")
        let last = app.textViews.element(boundBy: app.textViews.count - 1)
        last.press(forDuration: 1.0)
        let paste = app.descendants(matching: .any).matching(NSPredicate(format: "label IN {'Yapıştır', 'Paste'}")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        paste.tap()
        tapSystemButton(["Yapıştırmaya İzin Ver", "Allow Paste"], timeout: 2)
        sleep(2)
        snapshot("n3-pasted")
        app.buttons["Klavyeyi kapat"].firstMatch.tap()
        sleep(1)
        snapshot("n4-done")
        // Blok menüsü (⋮⋮): odaktaki satırda görünür; dokununca dönüştür / renk menüsü
        app.textViews.matching(NSPredicate(format: "value == 'Giriş paragrafı'")).firstMatch.tap()
        sleep(1)
        let handles = app.buttons.matching(identifier: "block-handle")
        print("HANDLES:", handles.count, handles.allElementsBoundByIndex.filter(\.isHittable).map(\.frame))
        snapshot("n5-focused")
        let visible = handles.allElementsBoundByIndex.first { $0.isHittable && abs($0.frame.midY - app.textViews.matching(NSPredicate(format: "value == 'Giriş paragrafı'")).firstMatch.frame.midY) < 20 }
        visible?.tap()
        sleep(1)
        snapshot("n6-block-menu")
        let quote = app.buttons["Alıntı"].firstMatch
        if quote.waitForExistence(timeout: 2) { quote.tap() }
        sleep(1)
        snapshot("n7-converted")
        let values = app.textViews.allElementsBoundByIndex.map { ($0.value as? String) ?? "" }
        print("BLOCKS:", values)
        XCTAssertTrue(values.contains("Proje planı"))
        XCTAssertTrue(values.contains("iki"))
        XCTAssertTrue(values.contains("ikinci"))
    }

    /// Hızlı bir insan gibi yaz (~12 harf/sn); XCUITest'in topluca yazması gerçekçi değil
    private func type(_ text: String) {
        for character in text {
            app.typeText(String(character))
            usleep(character == "\n" ? 400_000 : 80_000)
        }
    }

    private func tapSystemButton(_ titles: [String], timeout: TimeInterval) {
        for title in titles {
            let button = springboard.buttons[title]
            if button.waitForExistence(timeout: timeout) { button.tap(); return }
        }
    }

    private func snapshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/devnote-ui-\(name).png"))
    }
}
