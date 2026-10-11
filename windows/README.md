# DevNote — Windows

Mac / iPhone uygulamasının Windows sürümü. Aynı iCloud verisini (CloudKit kapsayıcısı `iCloud.com.efekan.devnote`, production) okur ve yazar; değişiklikler Mac'teki gibi anında gider.

- **Teknoloji:** Tauri 2 (Rust) + React + TypeScript. Arayüz Windows'un yerleşik WebView2 motorunda çalışır (Electron değil: kurulum ~3 MB).
- **Kurulum:** `DevNote_0.1.0_x64-setup.exe` — yönetici izni istemez, `%LOCALAPPDATA%\DevNote` altına yalnızca o kullanıcıya kurulur. Başlat menüsü kısayolu, kaldırıcı (Ayarlar → Uygulamalar) dahil.
- **Veri:** `%APPDATA%\com.efekan.devnote.windows\` (store.json, sync-state.json, assets\). Giriş belirteci ve API anahtarı **Windows Kimlik Bilgisi Yöneticisi**'nde ("DevNote") saklanır.

## Derleme (Mac'ten çapraz derleme)

```bash
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/opt/llvm/bin:$PATH"
cd windows
npm install
VITE_CK_API_TOKEN=<api-anahtarı> npm run build:win
# → src-tauri/target/x86_64-pc-windows-msvc/release/bundle/nsis/DevNote_0.1.0_x64-setup.exe
```

Gerekenler: `brew install rustup nsis llvm`, `rustup target add x86_64-pc-windows-msvc`, `cargo install cargo-xwin`.
`VITE_CK_API_TOKEN` verilmezse uygulama ilk açılışta anahtarı ister.

Arayüz testi (örnek veriyle, headless Chromium):

```bash
npx vite --port 5179 &   # tarayıcıda: http://localhost:5179/?demo
npm run test:ui
```

## iCloud için bir kerelik ayar (CloudKit Console)

1. https://icloud.developer.apple.com → **iCloud.com.efekan.devnote** → **API Access → API Tokens → +**
2. Ad: `DevNote Windows`, ortam: **Production**
3. **Sign In Callback:** `URL Redirect` → `cloudkit-icloud.com.efekan.devnote://` + `callback`
4. **Allowed Origins:** Any Domain
5. Oluşan anahtarı `VITE_CK_API_TOKEN` ile derlemeye gömün (önerilen) ya da uygulamada **Ayarlar → Senkron**'a yapıştırın.

Giriş: uygulama Apple'ın giriş sayfasını varsayılan tarayıcıda açar (şifre yalnızca Apple'a gider) → Apple tarayıcıyı `cloudkit-icloud.com.efekan.devnote://callback?…` adresine döndürür → Windows bu bağlantıyı DevNote'a verir (kurulum bağlantıyı yalnızca kullanıcı kaydına, HKCU, yazar). Belirteç Kimlik Bilgisi Yöneticisi'nde kalır; her bilgisayarda bir kez giriş yeter.

Şu anki anahtar "DevNote Windows" (production) derlemeye gömülüdür; yeni bilgisayarlarda anahtar girmek gerekmez.

## Senkron nasıl çalışıyor

| | Mac | Windows |
|---|---|---|
| Gönderme | kayıttan 150 ms sonra | kayıttan 150 ms sonra (`records/modify`, `update` + recordChangeTag) |
| Alma | açıkken 2–4 sn'de bir | açık ve odakta 2–4 sn, arka planda 16 sn (`changes/database` → `changes/zone`) |
| Çakışma | son yazan kazanır (`modifiedAt_`) | aynı |
| Görseller | CKAsset | aynı (`assets/upload`, indirilip diske yazılır) |
| Paylaşılan defterler | CKShare (bölge paylaşımı) | aynı paylaşım okunur; düzenleme, atama, yorum çalışır |

Windows'ta yapılamayanlar (Apple'a özgü): Apple Pencil çizimleri (PencilKit) gösterilemez ama silinmez/bozulmaz; yeni paylaşım daveti Apple'ın paylaşım ekranıyla Mac/iPhone'dan gönderilir (katılımcılar Windows'ta anında görünür).

## Yapay zeka (MCP)

Mac ile aynı: `http://127.0.0.1:7337/mcp` (yalnızca bu bilgisayar). Araçlar ve davranış birebir aynı.

```bash
claude mcp add --transport http devnote http://127.0.0.1:7337/mcp
```

## Antivirüs / SmartScreen

Uygulamada şüpheli sayılabilecek hiçbir şey yok: paketleyici (UPX) ya da gizleme kullanılmadı, yönetici izni istemez, sistem dosyalarına / kayıt defterinin HKLM kısmına dokunmaz, yalnızca 127.0.0.1'de dinler (güvenlik duvarı uyarısı çıkmaz), sürüm bilgisi (Şirket/Ürün/Telif) dolu.

İmzasız her yeni .exe için Windows SmartScreen "Windows kişisel bilgisayarınızı korudu" diyebilir (Ek bilgi → Yine de çalıştır). Kalıcı çözüm **kod imzası**:

- **Azure Trusted Signing** (~10 $/ay, en kolayı) ya da bir **OV/EV kod imzalama sertifikası** alın, sonra:
  ```bash
  brew install osslsigncode
  DEVNOTE_SIGN_PFX=/yol/sertifika.pfx DEVNOTE_SIGN_PASS=... npm run build:win
  ```
  `scripts/sign.sh` hem DevNote.exe'yi hem kurulum dosyasını imzalar (zaman damgalı).
- **Şirket içi:** BT ekibi Intune/Defender'da yayıncıya ya da dosya özetine (SHA-256) izin verebilir; kurum içi sertifikayla imzalanıp sertifika GPO ile dağıtılabilir.
- Yanlış alarm olursa: https://www.microsoft.com/wdsi/filesubmission ("Software developer" → yanlış pozitif).
