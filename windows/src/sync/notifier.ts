// Mac'teki TaskNotifier: bana atanan iş, atadığım işin tamamlanması, yorum / bahsetme, son tarih.
// Windows bildirimi (toast) + uygulama içi kart. Her veri değişikliğinde (600 ms toplanarak) yeniden hesaplanır.

import { useStore, type Rec } from '../model/store'
import { bk, pg } from '../model/ops'
import { plainText } from '../lib/markdown'
import { native } from '../lib/native'
import { useSettings, setSettings } from '../lib/settings'
import { toast } from '../ui/state'
import { get } from '../model/store'

let timer: ReturnType<typeof setTimeout> | undefined
const dueTimers = new Map<string, ReturnType<typeof setTimeout>>()

export function startNotifier() {
  let last = -1
  useStore.subscribe((s) => {
    if (s.version === last) return
    last = s.version
    clearTimeout(timer)
    timer = setTimeout(refresh, 600)
  })
  timer = setTimeout(refresh, 1500)
}

function place(block: Rec) {
  const page = get('Page', block.parent)
  const nb = get('Notebook', page?.parent)
  return [nb?.f.name_ as string | undefined, pg.title(page)].filter(Boolean).join(' · ')
}

function post(title: string, block: Rec, body?: string) {
  const text = body ?? plainText(bk.text(block))
  const where = place(block)
  void native.notify(title, where ? `${where}\n${text}` : text)
  toast(title, text, block.uuid)
}

function refresh() {
  const { recs, me } = useStore.getState()
  const myID = me.id
  if (myID === 'local-user') return
  const notified = new Set(useSettings.getState().notified)
  const primed = useSettings.getState().primed
  const all = Object.values(recs)
  const blocks = all.filter((r) => r.entity === 'Block')
  const now = Date.now()

  // 1) Bana atanan yeni işler
  for (const b of blocks) {
    if (bk.kind(b) !== 'checklist' || bk.done(b) || b.f.assigneeID_ !== myID) continue
    const key = `assign-${b.uuid}-${myID}`
    if (notified.has(key)) continue
    notified.add(key)
    if (primed && b.f.assignedByID_ !== myID) post(`${(b.f.assignedByName_ as string) || 'Bir ekip üyesi'} sana bir iş atadı`, b)
  }
  // 2) Atadığım işler başkası tarafından tamamlandı
  for (const b of blocks) {
    if (!bk.done(b) || b.f.assignedByID_ !== myID || b.f.doneByID_ === myID) continue
    const doneAt = Number(b.f.doneAt_ ?? 0)
    if (doneAt < now - 86_400_000) continue
    const key = `done-${b.uuid}-${Math.round(doneAt / 1000)}`
    if (notified.has(key)) continue
    notified.add(key)
    if (primed) post(`${(b.f.doneByName_ as string) || (b.f.assigneeName_ as string) || 'Bir ekip üyesi'} görevi tamamladı ✓`, b)
  }
  // 3) Yorumlar
  for (const c of all) {
    if (c.entity !== 'Comment' || c.f.authorID_ === myID) continue
    if (Number(c.f.createdAt_ ?? 0) < now - 3 * 86_400_000) continue
    const block = get('Block', c.parent)
    if (!block) continue
    const key = `comment-${c.uuid}`
    if (notified.has(key)) continue
    notified.add(key)
    if (!primed) continue
    const author = (c.f.authorName_ as string) || 'Biri'
    const mentions = String(c.f.mentionIDs_ ?? '').split(',')
    const title = mentions.includes(myID) ? `${author} senden bahsetti`
      : block.f.assigneeID_ === myID ? `${author} görevine yorum yaptı`
      : block.f.assignedByID_ === myID ? `${author} atadığın göreve yorum yaptı` : null
    if (title) post(title, block, `„${plainText(String(c.f.text_ ?? ''))}“ — ${plainText(bk.text(block))}`)
  }
  setSettings({ notified: [...notified].slice(-2000), primed: true })

  // 4) Son tarih hatırlatmaları (uygulama açıkken)
  const wanted = new Set<string>()
  for (const b of blocks) {
    const due = Number(b.f.dueDate_ ?? 0)
    if (bk.kind(b) !== 'checklist' || bk.done(b) || !due || due <= now) continue
    if (b.f.assigneeID_ && b.f.assigneeID_ !== myID) continue
    const key = `${b.uuid}-${due}`
    wanted.add(key)
    if (dueTimers.has(key) || due - now > 2 ** 31 - 1) continue
    dueTimers.set(key, setTimeout(() => {
      dueTimers.delete(key)
      const fresh = get('Block', b.uuid)
      if (fresh && !bk.done(fresh)) post('⏰ Süre doldu', fresh)
    }, due - now))
  }
  for (const [key, t] of dueTimers) if (!wanted.has(key)) { clearTimeout(t); dueTimers.delete(key) }
}
