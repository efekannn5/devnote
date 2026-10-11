# DevNote

Yapay zekaların MCP üzerinden okuyup **checklist maddelerini tamamlandı olarak işaretleyebildiği**,
Apple tasarım diline uygun, çok platformlu bir not uygulaması.

## Durum (taslak v0.1)

| Platform | Durum |
|---|---|
| macOS | ✅ SwiftUI + Core Data, uygulama içi MCP sunucusu |
| iOS / iPadOS | ✅ Aynı kod tabanı derleniyor (MCP yok) |
| iCloud senkron | ✅ Core Data + CloudKit, Mac ↔ iPhone test edildi |
| Paylaşılan defterler | ✅ CloudKit paylaşımı (davet, yetki, iş atama, hatırlatma) — 2. Apple ID ile test bekliyor |
| Windows / Android sunucusu | ⏳ Sonraki aşama |
| Windows / Android | ⏳ Sonraki aşama |

## Özellikler

- **Defterler** (renk + SF Symbol ikonu), sürükle-bırak sıralama
- **Akıllı listeler**: Tüm Notlar, Sabitlenenler, Açık Görevler, AI Tamamladı
- **İki görünüm**, not oluşturulurken seçilir (⌘N belge, ⇧⌘N tuval; sonradan değişmez):
  - **Belge** — Notion gibi bloklar: metin, başlık 1–3, madde, numaralı liste, yapılacak, alıntı, kod, ayırıcı, görsel.
    Enter bloğu imleçten böler, satır başında ⌫ önceki blokla birleştirir, Tab / ⇧Tab girinti, ↑↓ bloklar arası.
    `/` ile filtrelenen blok menüsü, satır solunda `+` ve `⋮⋮` (sürükle: taşı · tıkla: dönüştür, renk, yorum, çoğalt, sil),
    sayfa sonunda "+ Blok ekle". Yapıştırılan Markdown bloklara bölünür.
  - **Tuval** — OneNote gibi: boş bir yere tıkla, yazmaya başla (Enter yeni satır); kutuları tutamaçtan sürükle, genişliğini ayarla
- **Markdown kısayolları**: `#`/`##`/`###` başlık, `- ` madde, `1. ` numaralı, `[] ` yapılacak, `> ` alıntı, ` ``` ` kod, `--- ` ayırıcı
- Boş liste maddesinde Enter → önce girinti azalır, sonra normal metne döner
- **AI rozeti**: Yapay zekanın işaretlediği maddelerde ✨ rozeti; tıklayınca yapay zekanın bıraktığı açıklama görünür
- İlerleme halkaları, arama, sabitleme, deftere taşıma, yay (spring) animasyonları
- **Zengin metin** (Word gibi): kalın / italik / altı çizili / üstü çizili / kod / bağlantı, yazı rengi, arka plan rengi,
  px cinsinden boyut, biçimi temizle. Mac ve iPad'de üstte biçim çubuğu, iPhone'da klavye üstünde (+ blok ekle, tür, biçimler).
  Markdown olarak saklanır; ⌘B, ⌘I, ⌘U, ⇧⌘X, ⌘E, ⌘K, ⇧⌘H, ⌘+ / ⌘- / ⌘0, ⌘\
- **Görseller**: Fotoğraflar'dan, dosyadan ya da sürükle-bırak; tam ekran yakınlaştırma, paylaşma
- **Bloğu sürükle-sırala** (belge), **tuvalde çizim** (iPhone/iPad: parmak veya Pencil; tek parmak çizer, iki parmak kaydırır; Mac'te görüntülenir)
- **Yorumlar ve @bahsetme**: göreve yorum yaz, `@İsim` ile ekip arkadaşına bildirim; Ekip ekranında **Son etkinlikler** akışı
- **Widget**: "Görevlerim" (küçük / orta / büyük + kilit ekranı); ✓ ile uygulamayı açmadan tamamla
- **Siri / Kestirmeler**: "DevNote'a görev ekle", "DevNote'ta açık görevlerim"

## Çalıştırma

```bash
brew install xcodegen
xcodegen generate
open DevNote.xcodeproj        # DevNote-macOS şemasını çalıştır
```

> Not: Proje `~/Documents` içinde ve bu klasör iCloud ile senkronlanıyorsa, komut satırından
> derlerken `-derivedDataPath /tmp/devnote-build` kullan. Aksi halde codesign
> "resource fork… detritus" hatası verir.

## MCP (Yapay Zeka Katmanı)

Mac uygulaması açıkken `http://127.0.0.1:7337/mcp` adresinde **Streamable HTTP** MCP sunucusu çalışır.
Sadece loopback'te dinler, yabancı `Origin` başlıklarını reddeder. Ayarlar (⌘,) → *Yapay Zeka*
sekmesinden açıp kapatabilir, portu değiştirebilirsin.

**Claude Code:**
```bash
claude mcp add --transport http devnote http://127.0.0.1:7337/mcp
```

**Sadece stdio destekleyen istemciler (ör. Claude Desktop):**
```json
{ "mcpServers": { "devnote": { "command": "npx", "args": ["-y", "mcp-remote", "http://127.0.0.1:7337/mcp"] } } }
```

### Araçlar

| Araç | Açıklama |
|---|---|
| `list_notebooks` | Defterleri listeler |
| `list_pages` | Sayfaları listeler (defter filtresi) |
| `read_page` | Sayfayı blok id'leriyle Markdown olarak döndürür |
| `list_open_tasks` | Açık yapılacakları `task_id`, atanan kişi ve son tarihle listeler (`assignee: "me"` → yalnızca bana atananlar) |
| `list_people` | Paylaşılan defterlerdeki ekip üyeleri, rolleri ve açık görev sayıları |
| `assign_task` | Görevi bir kişiye atar (`person`: `"me"` ya da isim; boş = atamayı kaldır) |
| `set_due_date` | Son tarih / hatırlatma (ISO 8601; boş = kaldır) |
| `list_comments` | Görevin yorumları |
| `add_comment` | Göreve yapay zeka adına yorum (`@İsim` → bildirim) |
| `complete_task` | Maddeyi **AI tarafından** tamamlandı işaretler + açıklama (`note`) |
| `reopen_task` | Maddeyi yeniden açar |
| `add_task` | Sayfaya yeni madde ekler |
| `create_page` | Markdown içerikle yeni sayfa (defter yoksa oluşturur) |
| `append_to_page` | Sayfanın sonuna Markdown ekler |
| `search` | Tüm notlarda arama |

Id'ler 8 karakterlik kısa UUID önekleridir. Değişiklikler uygulamanın ana `viewContext`'i üzerinden
yapıldığı için arayüzde **anında ve animasyonlu** görünür.

Ekip akışı örneği — yapay zekaya *"bana atanan işlere bak, bitenleri işaretle"* dersin:
`list_open_tasks(assignee: "me")` → işi kontrol eder → `complete_task(note: …)`. Atayan kişi
"Yapay zeka (Adın) görevi tamamladı ✓" bildirimini alır, Dynamic Island'daki görev kapanır.

Hızlı test:
```bash
curl -s http://127.0.0.1:7337/mcp -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_open_tasks","arguments":{}}}'
```

## iCloud & paylaşım

- Veri katmanı **Core Data** (yerel) + **CKSyncEngine** (iCloud). Kendi defterlerin private DB'de, seninle paylaşılanlar shared DB'de.
- Container: `iCloud.com.efekan.devnote`, Team `896PY6QKL9`. Kapatmak için `project.yml`'den `ICLOUD_SYNC`'i kaldır.
- **Paylaşma:** kenar çubuğunda deftere sağ tık / uzun bas → *Paylaş…* (Mesajlar, Mail, link). Katılımcılara düzenleme ya da salt okunur yetki verilir.
- **İş atama:** paylaşılan defterde bir maddeye sağ tık → *Ata* → kişi. Atanan kişiye bildirim gider; *Bana Atananlar* listesinde görünür.
- **Hatırlatma:** maddeye sağ tık → *Hatırlatma Ekle…* → tarih. Atanan kişinin (ya da atanmamışsa herkesin) cihazında yerel bildirim.
- **Ekip ekranı:** sayfa araç çubuğunda *Ekip* → üyeler (sahip / düzenleyebilir / davet bekliyor), her kişinin açık
  görevleri, atanmamış görevleri tek dokunuşla atama, *Ekip arkadaşı davet et* (iCloud daveti).
- **Bildirimler:** bana iş atanınca *zamana duyarlı* bildirim (Odak modunu deler), atadığım işi biri bitirince
  "X görevi tamamladı ✓", son tarih gelince "⏰ Süre doldu". Bildirimde **Tamamla** düğmesi var.
- **Dynamic Island / kilit ekranı (iPhone):** bana atanan görev otomatik olarak Live Activity olur — küçük halde
  ilerleme halkası + geri sayım, uzun basınca başlık, atayan kişi ve **Tamamla** düğmesi (uygulamayı açmadan).
  Herhangi bir maddeye uzun bas → *Dynamic Island'da takip et*.
- Örnek içerik yalnızca Mac'te ilk açılışta oluşur; iPhone iCloud'dan alır.
- Hata ayıklama: Mac uygulamasını terminalden `NSUnbufferedIO=YES .../DevNote.app/Contents/MacOS/DevNote` ile çalıştırınca `☁️` (iCloud) ve `⚡` (yakın cihaz) satırları senkron olaylarını gösterir.

## Hatalar ve çökmeler

- Her hata (kaydetme, iCloud, MCP, yakın cihaz…) `ErrorReporter` üzerinden **günlüğe yazılır**
  (`Application Support/Logs/devnote-errors.log`) ve ekranın üstünde kısa bir uyarı çıkar.
  Uygulama arka plandaysa bildirim olarak gelir. Uygulama kapanmaz, kaldığın yerden devam edersin.
- Kendiliğinden düzelen hatalar (ağ yok, iCloud meşgul, iCloud'a giriş yapılmamış) yalnızca günlüğe yazılır.
  Aynı hata 1 dakika içinde tekrar uyarı göstermez.
- Veri deposu açılamazsa uygulama kapanmaz: bozuk dosya yedeklenir, yenisi açılır (iCloud verileri geri gelir).
- Gerçek bir çökme engellenemez. Ama son anda kayıt düşülür ve sonraki açılışta
  "Uygulama geçen sefer kapandı" uyarısı gösterilir.
- Kayıtlar: kenar çubuğunun altındaki 🔍 / ⚠️ düğmesi → *Hata Kayıtları* (paylaş / temizle).
- Debug: `devnote://debug/error` (örnek uyarı), `devnote://debug/crash` (gerçek çökme).

## Logo

`Tools/make-icon.swift` logoyu vektörel çizer ve `DevNote/Assets.xcassets` içine iOS (tam kare) ve
Mac (gölgeli plaka) ikonlarını üretir: `swift Tools/make-icon.swift DevNote/Assets.xcassets`

## Senkron mimarisi

| Yol | Ne zaman | Ölçülen gecikme |
|---|---|---|
| **iCloud — CKSyncEngine** (`CloudSync`) | Her zaman, her yerde | Mac → iPhone **< 5 sn** |
| **Yakın cihaz** (`PeerSync`) | Aynı Wi‑Fi / doğrudan Wi‑Fi / USB | **< 1 sn** |

- Kaydedince hemen gönderilir; push gelince ve uygulama açıkken 2-4 sn'de bir değişiklik sorulur
  (Mac arka plandayken 20 sn). NSPersistentCloudKitContainer'ın kendi zamanlamasına bağlı değiliz.
- Her defter kendi CloudKit bölgesinde (`nb-<uuid>`); paylaşım bölge düzeyinde (`CKShare(recordZoneID:)`).
- Kayıt adı `<Entity>.<uuid>` → aynı nesne iki kez oluşamaz; iki yol aynı kayıtta buluşur.
- Çakışma: her nesnede `modifiedAt_`, son yazan kazanır.
- Yakın cihaz yolundan gelen değişiklikler iCloud'a tekrar gönderilmez (kaynak cihaz gönderir).
  Bağlantı TLS-PSK ile şifreli; anahtar iCloud kullanıcı kimliğinden türetilir. Her cihaz kalıcı
  kimlikle bir kez listelenir.
- Test: Mac'i `DEVNOTE_NO_PEER=1` ile çalıştırınca yalnızca iCloud yolu ölçülür.
- İlk açılışta eski (NSPersistentCloudKitContainer) deposu bir kez yeni depoya taşınır.

### Simülatörde deneme (iCloud hesabı gerekmez)
```bash
SIM=<simülatör-id>
xcodebuild -scheme DevNote-iOS -destination "id=$SIM" -derivedDataPath /tmp/devnote-build build-for-testing
xcrun simctl install $SIM /tmp/devnote-build/Build/Products/Debug-iphonesimulator/DevNote.app
# bildirim iznini ver, sonra demo: "Ayşe sana iş atadı" → banner + Dynamic Island (ekran görüntüleri /tmp/devnote-ui-*.png)
xcodebuild -scheme DevNote-iOS -destination "id=$SIM" -derivedDataPath /tmp/devnote-build test-without-building \
  -only-testing:DevNoteUITests/SimulatorFlowTests/testAllowNotifications
TEST_RUNNER_DEMO=assign    xcodebuild ... -only-testing:DevNoteUITests/SimulatorFlowTests/testDemo
TEST_RUNNER_DEMO=completed xcodebuild ... -only-testing:DevNoteUITests/SimulatorFlowTests/testDemo
xcodebuild ... -only-testing:DevNoteUITests/SimulatorFlowTests/testCompleteFromIsland   # Island'dan tamamla
xcodebuild ... -only-testing:DevNoteUITests/SimulatorFlowTests/testCanvasDrag            # tuval kartı parmağı birebir izler
xcodebuild ... -only-testing:DevNoteUITests/SimulatorFlowTests/testCanvasDrawing         # tuvalde çizim
xcodebuild ... -only-testing:DevNoteUITests/SimulatorFlowTests/testMentionAndActivity    # @bahsetme bildirimi + etkinlik akışı
xcodebuild ... -only-testing:DevNoteUITests/SimulatorFlowTests/testHomeWidget            # widget ekle, ✓ ile tamamla
```
(Debug derlemede `devnote://debug/assign`, `completed`, `mention`, `editor` adresleri demo veri üretir.)

iOS ilk açılışta "yerel ağdaki cihazları bul" izni ister — izin verilmezse sadece iCloud çalışır.

## Mimari

```
DevNote/
  App/DevNoteApp.swift        Uygulama girişi, MCP ve bildirimleri başlatma
  App/AppDelegate.swift       iCloud davet kabulü, ShareLink için NotebookShareItem
  Models/Models.swift         Notebook → Page → Block (Core Data, programatik model)
  Models/Persistence.swift    Yerel Core Data deposu, otomatik kayıt, paylaşım yardımcıları, eski depodan taşıma
  Models/CloudSync.swift      iCloud senkronu (CKSyncEngine, private + shared veritabanı, bölge paylaşımı)
  Models/TaskNotifier.swift   Atama, tamamlanma & son tarih bildirimleri (Tamamla düğmesiyle)
  Models/TaskActions.swift    Ortak görev işlemleri + Live Activity yönetimi
  Models/ErrorReporter.swift  Hata günlüğü, uyarılar, çökme kaydı
  Views/ErrorViews.swift      Hata uyarısı ve Hata Kayıtları ekranı
  Views/TeamView.swift        Ekip ekranı: üyeler, görevleri, davet, atama
Shared/TaskActivity.swift     Live Activity verisi + "Tamamla" App Intent'i (uygulama + widget)
Shared/WidgetSnapshot.swift   Widget'ın okuduğu görev özeti (App Group: group.com.efekan.devnote)
DevNoteWidgets/               Dynamic Island, kilit ekranı ve "Görevlerim" widget'ı
DevNoteUITests/               Simülatör akışları (izin, demo, Island'dan tamamlama)
  Models/PeerSync.swift       Yakın cihazlar arası anlık senkron (Network.framework, TLS-PSK)
  Models/SampleData.swift     İlk açılışta örnek içerik
  Views/                      Sidebar, PageList, PageEditor (Belge + Tuval), BlockRow, Settings
  MCP/MCPServer.swift         Network.framework ile minimal HTTP sunucu (yalnız macOS)
  MCP/MCPTools.swift          JSON-RPC: initialize, ping, tools/list, tools/call
```

## Yol haritası

- **Gruplar / yerel sunucu**: Paylaşılan defterler için küçük bir senkron sunucusu (Vapor veya Go),
  LAN'da Bonjour ile keşif. Model zaten UUID tabanlı, buna hazır.
- **Windows / Android**: Sunucunun API'si üzerinden; büyük ihtimalle Kotlin Multiplatform / Compose
  ya da Flutter. MCP katmanı sunucuya da taşınabilir.
- **Editör**: sesli not + transkript, etiketler, sayfa şablonları; Mac'te widget.
- **MCP**: ekleme/değişiklik bildirimleri (`notifications/resources`), sayfaları MCP *resource* olarak
  yayınlama, isteğe bağlı erişim token'ı.
