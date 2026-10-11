// Tarayıcıda arayüz testi için örnek veri (?demo). Uygulamada (Tauri) hiç çalışmaz.

import { update, useStore, setShares, setMe } from './model/store'
import { addBlock, addComment, createNotebook, createPage, setDone } from './model/ops'

export function seedDemo() {
  if (Object.keys(useStore.getState().recs).length) return
  setMe({ id: '_me', name: 'Ben', isMe: true })
  const work = createNotebook('Ekip', 'person.2.fill', '#0A84FF', 0)
  createNotebook('Kişisel', 'heart.fill', '#FF375F', 1)
  setShares({
    [`${work.zoneOwner}/${work.zoneName}`]: {
      zone: `${work.zoneOwner}/${work.zoneName}`, myPermission: 'READ_WRITE',
      participants: [
        { id: '_me', name: 'Efekan', isMe: true, permission: 'READ_WRITE', accepted: true, owner: true },
        { id: '_ayse', name: 'Ayşe Yılmaz', isMe: false, permission: 'READ_WRITE', accepted: true, owner: false },
      ],
    },
  })
  const page = createPage('Sprint planı', work, 'document')
  const first = Object.values(useStore.getState().recs).find((r) => r.entity === 'Block' && r.parent === page.uuid)!
  update(first, { kind_: 'heading', text_: 'Bu hafta' })
  addBlock(page, 'text', '**Kalın**, _italik_, ~~üstü çizili~~, `kod` ve [bağlantı](https://apple.com) desteği. ^[Vurgulu](highlight: \'#FFD60A\') ve ^[renkli](color: \'#FF453A\') metin.')
  const task = addBlock(page, 'checklist', 'Tasarım ekranlarını **cuma** gününe kadar bitir')
  update(task, { assigneeID_: '_ayse', assigneeName_: 'Ayşe Yılmaz', assignedByID_: '_me', assignedByName_: 'Efekan', assignedAt_: Date.now() - 600_000, dueDate_: Date.now() + 2 * 86_400_000 })
  addComment(task, 'İlk taslak hazır, bakar mısın @Ayşe Yılmaz?', [{ id: '_ayse', name: 'Ayşe Yılmaz' }])
  const done = addBlock(page, 'checklist', 'Müşteri toplantısı notlarını paylaş')
  setDone(done, true, 'ai', 'Notlar sayfaya eklendi ve ekibe gönderildi.')
  addBlock(page, 'bullet', 'Birinci madde')
  addBlock(page, 'bullet', 'Alt madde', null, { indent: 1 })
  addBlock(page, 'numbered', 'Numaralı bir')
  addBlock(page, 'numbered', 'Numaralı iki')
  addBlock(page, 'quote', 'Basit olan güzeldir.')
  addBlock(page, 'code', 'npm run tauri build')
  addBlock(page, 'divider', '')
  addBlock(page, 'text', '')
  const canvas = createPage('Fikir panosu', work, 'canvas')
  addBlock(canvas, 'heading2', 'Fikirler', null, { x: 60, y: 40, width: 300, isPlaced: true })
  addBlock(canvas, 'checklist', 'Windows sürümü', null, { x: 60, y: 110, width: 280, isPlaced: true })
  addBlock(canvas, 'text', 'Serbest kutu — sürükle, genişlet', null, { x: 420, y: 80, width: 260, isPlaced: true })
}
