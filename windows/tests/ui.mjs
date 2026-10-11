// Arayüz testi: headless Chromium'da örnek veriyle (?demo) uygulamanın akışları.
//   npx vite --port 5179 & node tests/ui.mjs
import { chromium } from 'playwright'

const out = process.env.OUT ?? '/tmp'
// Windows'ta Ctrl / Home; testler Mac'te çalışırsa Cmd / Cmd+←
const MOD = process.platform === 'darwin' ? 'Meta' : 'Control'
const HOME = process.platform === 'darwin' ? 'Meta+ArrowLeft' : 'Home'
const END = process.platform === 'darwin' ? 'Meta+ArrowRight' : 'End'
const browser = await chromium.launch()
const errors = []
const results = []
const check = (name, ok, detail = '') => { results.push(`${ok ? '✓' : '✗'} ${name}${detail ? ' — ' + detail : ''}`); if (!ok) process.exitCode = 1 }

async function run(scheme) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 820 }, colorScheme: scheme, deviceScaleFactor: 1 })
  page.on('pageerror', (e) => errors.push(`${scheme}: ${e.message}`))
  page.on('console', (m) => { if (m.type() === 'error') errors.push(`${scheme} console: ${m.text()}`) })
  await page.goto('http://localhost:5179/?demo')
  await page.getByText('Şimdilik iCloud olmadan devam et').click()
  await page.getByText('Sprint planı').first().click()
  await page.waitForTimeout(300)
  await page.screenshot({ path: `${out}/doc-${scheme}.png` })
  return page
}

const page = await run('light')
const blocks = () => page.evaluate(() => {
  const raw = JSON.parse(localStorage.getItem('devnote:store.json') ?? '{"recs":[]}')
  return raw.recs
})
const texts = async () => (await page.$$eval('.blk', (els) => els.map((e) => [e.className.split(' ')[1], e.innerText.replace(/\n$/, '')])))

// 1) Son boş satıra Markdown kısayollarıyla yaz
const last = page.locator('.blk .rt').last()
await last.click()
await page.keyboard.type('# Başlık deneme', { delay: 15 })
await page.keyboard.press('Enter')
await page.keyboard.type('[] yeni görev', { delay: 15 })
await page.keyboard.press('Enter')
await page.keyboard.type('ikinci görev', { delay: 15 })
await page.keyboard.press('Enter')
await page.keyboard.press('Enter') // boş yapılacakta Enter → metne döner
await page.keyboard.type('düz metin', { delay: 15 })
await page.waitForTimeout(200)
let t = await texts()
const tail = t.slice(-4)
check('Markdown kısayolu: # → Başlık 1', tail[0]?.[0] === 'k-heading' && tail[0][1] === 'Başlık deneme', JSON.stringify(tail[0]))
check('[] → yapılacak, Enter aynı türde devam', tail[1]?.[0] === 'k-checklist' && tail[2]?.[0] === 'k-checklist', JSON.stringify(tail.slice(1, 3)))
check('Boş maddede Enter → metin', tail[3]?.[0] === 'k-text' && tail[3][1] === 'düz metin', JSON.stringify(tail[3]))

// 2) Kalın biçim (Ctrl+B) Markdown olarak saklanır
await page.keyboard.press(`Shift+${HOME}`)
await page.keyboard.press(`${MOD}+b`)
await page.waitForTimeout(500)
let recs = await blocks()
check('Ctrl+B → **kalın** olarak kaydedildi', recs.some((r) => r.f.text_ === '**düz metin**'), recs.filter((r) => r.entity === 'Block').map((r) => r.f.text_).slice(-2).join(' | '))

// 3) Enter ile bölme: imleçten sonrası yeni bloğa
await page.keyboard.press(END)
await page.keyboard.press('Enter')
await page.keyboard.type('bölünecek metin', { delay: 15 })
for (let i = 0; i < 5; i++) await page.keyboard.press('ArrowLeft')  // beklemeden: Enter eski imleci görmemeli
await page.keyboard.press('Enter')
await page.waitForTimeout(200)
t = await texts()
check('Enter imleçte böler', t.at(-2)?.[1] === 'bölünecek ' && t.at(-1)?.[1] === 'metin', JSON.stringify(t.slice(-2)))

// 4) Satır başında ⌫ önceki satırla birleştirir
await page.keyboard.press(HOME)
await page.keyboard.press('Backspace')
await page.waitForTimeout(200)
t = await texts()
check('⌫ birleştirir', t.at(-1)?.[1] === 'bölünecek metin', JSON.stringify(t.at(-1)))

// 5) "/" menüsü
await page.keyboard.press(END)
await page.keyboard.press('Enter')
await page.keyboard.type('/kod', { delay: 30 })
const slashVisible = await page.getByTestId('slash-menu').isVisible()
await page.screenshot({ path: `${out}/slash.png` })
await page.keyboard.press('Enter')
await page.keyboard.type('npm test', { delay: 15 })
await page.waitForTimeout(200)
t = await texts()
check('"/" menüsü açılır ve Kod seçilir', slashVisible && t.at(-1)?.[0] === 'k-code' && t.at(-1)?.[1] === 'npm test', JSON.stringify(t.at(-1)))

// 6) Biçim çubuğu: px boyut
await page.keyboard.press(`Shift+${HOME}`)
const size = page.getByTestId('font-size-field')
await size.fill('24')
await size.press('Enter')
await page.waitForTimeout(500)
recs = await blocks()
check('Boyut kutusu → size: 24', recs.some((r) => /size: 24/.test(r.f.text_ ?? '')), recs.filter((r) => r.entity === 'Block').map((r) => r.f.text_).at(-1))

// 7) ⋮⋮ blok menüsü
await page.locator('.blk-wrap').nth(1).hover()
await page.locator('.blk-wrap').nth(1).getByTestId('block-handle').click()
const menuOK = await page.getByTestId('block-menu').isVisible()
await page.screenshot({ path: `${out}/block-menu.png` })
await page.keyboard.press('Escape')
check('⋮⋮ blok menüsü açılır', menuOK)

// 8) Tik → tamamlandı
const checks = page.locator('.check')
const before = await page.locator('.check.on').count()
await checks.first().click()
await page.waitForTimeout(150)
check('Yapılacak işaretlenir', (await page.locator('.check.on').count()) === before + 1)

// 9) Sürükleyerek taşı: ilk bloğu üçüncünün altına
const firstText = (await texts())[0][1]
const handle = page.locator('.blk-wrap').nth(0).getByTestId('block-handle')
await page.locator('.blk-wrap').nth(0).hover()
const hb = await handle.boundingBox()
const target = await page.locator('.blk-wrap').nth(3).boundingBox()
await page.mouse.move(hb.x + 5, hb.y + 5)
await page.mouse.down()
await page.mouse.move(hb.x + 5, hb.y + 30, { steps: 4 })
await page.mouse.move(hb.x + 5, target.y + target.height - 2, { steps: 6 })
await page.mouse.up()
await page.waitForTimeout(200)
t = await texts()
check('Tutamaçla sürükleyip taşıma', t[0][1] !== firstText && t.findIndex((x) => x[1] === firstText) > 0, `ilk: ${t[0][1]}`)

// 10) Yorumlar
await page.locator('.chip').first().click()
await page.waitForTimeout(150)
await page.screenshot({ path: `${out}/comments.png` })
await page.keyboard.type('Teşekkürler @Ay', { delay: 15 })
const mentionShown = await page.locator('.mention-chip').count()
await page.locator('.mention-chip').first().click()
await page.keyboard.press('Enter')
await page.waitForTimeout(150)
recs = await blocks()
check('Yorum + @bahsetme', mentionShown > 0 && recs.some((r) => r.entity === 'Comment' && r.f.mentionIDs_ === '_ayse'))
await page.getByText('Bitti').click()

// 11) Tuval
await page.getByText('Fikir panosu').first().click()
await page.waitForTimeout(300)
await page.screenshot({ path: `${out}/canvas.png` })
const card = page.locator('.card').first()
await card.hover()
const handleBox = await card.getByTestId('canvas-handle').boundingBox()
const startPos = await card.boundingBox()
await page.mouse.move(handleBox.x + handleBox.width / 2, handleBox.y + 6)
await page.mouse.down()
await page.mouse.move(handleBox.x + 200, handleBox.y + 120, { steps: 8 })
await page.mouse.up()
await page.waitForTimeout(200)
const endPos = await page.locator('.card').first().boundingBox()
check('Tuval kartı sürüklenir', Math.abs(endPos.x - startPos.x - 200 + handleBox.width / 2) < 30 && endPos.y > startPos.y + 80, `${startPos.x},${startPos.y} → ${endPos.x},${endPos.y}`)
// Boş tuvale tıkla → yeni kutu; yazmadan bırak → silinir
const cardsBefore = await page.locator('.card').count()
await page.getByTestId('canvas').click({ position: { x: 900, y: 500 } })
await page.waitForTimeout(150)
const cardsAfterTap = await page.locator('.card').count()
await page.keyboard.type('Yeni kutu', { delay: 15 })
await page.keyboard.press('Enter')
await page.keyboard.type('ikinci satır', { delay: 15 })
await page.getByTestId('canvas').click({ position: { x: 1400, y: 900 } })
await page.waitForTimeout(150)
await page.getByTestId('canvas').click({ position: { x: 1400, y: 300 } })
await page.waitForTimeout(150)
await page.getByTestId('canvas').click({ position: { x: 1500, y: 1000 } })
await page.waitForTimeout(700)
recs = await blocks()
check('Tuvale tıklayınca kutu, Enter yeni satır, boş kutu silinir',
  cardsAfterTap === cardsBefore + 1 && recs.some((r) => r.f.text_ === 'Yeni kutu\nikinci satır') && (await page.locator('.card').count()) === cardsBefore + 1,
  `${cardsBefore} → ${cardsAfterTap} → ${await page.locator('.card').count()} ${JSON.stringify(recs.filter((r) => r.entity === 'Block').map((r) => r.f.text_).slice(-3))}`)

// 12) Yeni not menüsü
await page.getByTestId('new-note').click()
await page.screenshot({ path: `${out}/new-note.png` })
await page.getByText('Belge — Notion gibi bloklar').click()
await page.keyboard.type('Yeni sayfa başlığı', { delay: 10 })
await page.keyboard.press('Enter')
await page.keyboard.type('ilk satır', { delay: 10 })
await page.waitForTimeout(700)
recs = await blocks()
check('Yeni belge: başlık + Enter ile ilk satır', recs.some((r) => r.entity === 'Page' && r.f.title_ === 'Yeni sayfa başlığı') && recs.some((r) => r.f.text_ === 'ilk satır'), JSON.stringify(recs.filter((r) => r.entity === 'Page').map((r) => r.f.title_)) + ' ' + JSON.stringify(recs.filter((r) => r.entity === 'Block').map((r) => r.f.text_).slice(-2)))

// 13) Sağ tık menüsü
await page.locator('.page-row').first().click({ button: 'right' })
await page.screenshot({ path: `${out}/context.png` })
await page.keyboard.press('Escape')

// 14) Ekip
await page.getByText('Sprint planı').first().click()
await page.locator('[title="Ekip, davet ve görev atama"]').click()
await page.waitForTimeout(200)
await page.screenshot({ path: `${out}/team.png` })
await page.keyboard.press('Escape')

const dark = await run('dark')
await dark.getByText('Fikir panosu').first().click()
await dark.waitForTimeout(200)
await dark.screenshot({ path: `${out}/canvas-dark.png` })

console.log(results.join('\n'))
console.log(errors.length ? 'HATALAR:\n' + errors.join('\n') : 'Konsol hatası yok')
await browser.close()
