// Mac'teki model işlemlerinin (Notebook.create, Page.addBlock, Block.setDone…) birebir karşılıkları.

import { DEFAULT_OWNER, type Entity } from './schema'
import type { BlockKind, MarkdownItem } from '../lib/markdown'
import {
  field, get, insert, isMine, newUUID, remove, update, useStore,
  type AssetRef, type Person, type Rec,
} from './store'

export type PageLayout = 'document' | 'canvas'
export type { BlockKind }

// MARK: - Erişimciler

export const nb = {
  name: (r?: Rec) => field<string>(r, 'name_') ?? '',
  icon: (r?: Rec) => field<string>(r, 'icon_') ?? 'book.closed.fill',
  color: (r?: Rec) => field<string>(r, 'colorHex_') ?? '#0A84FF',
}

export const pg = {
  title: (r?: Rec) => field<string>(r, 'title_') ?? '',
  layout: (r?: Rec): PageLayout => (field<string>(r, 'layout_') === 'canvas' ? 'canvas' : 'document'),
  pinned: (r?: Rec) => !!field<boolean>(r, 'isPinned'),
  updatedAt: (r?: Rec) => field<number>(r, 'updatedAt_') ?? 0,
}

const KINDS: BlockKind[] = ['text', 'heading', 'heading2', 'heading3', 'checklist', 'bullet', 'numbered', 'quote', 'code', 'divider', 'image']

export const bk = {
  kind: (r?: Rec): BlockKind => {
    const k = field<string>(r, 'kind_') as BlockKind
    return KINDS.includes(k) ? k : 'text'
  },
  text: (r?: Rec) => field<string>(r, 'text_') ?? '',
  order: (r?: Rec) => field<number>(r, 'order') ?? 0,
  indent: (r?: Rec) => Number(field<number>(r, 'indent') ?? 0),
  done: (r?: Rec) => !!field<boolean>(r, 'isDone'),
}

// MARK: - Kimlik

export function me(): Person { return useStore.getState().me }

/** Paylaşılan defterlerde kendi görünen adım (Mac: myDisplayName) */
export function myDisplayName(notebook?: Rec): string | null {
  if (!notebook) return null
  const share = useStore.getState().shares[`${notebook.zoneOwner}/${notebook.zoneName}`]
  return share?.participants.find((p) => p.isMe)?.name ?? null
}

export function notebookOf(r?: Rec): Rec | undefined {
  if (!r) return undefined
  if (r.entity === 'Notebook') return r
  if (r.entity === 'Page') return get('Notebook', r.parent)
  if (r.entity === 'Block') return notebookOf(get('Page', r.parent))
  if (r.entity === 'Comment') return notebookOf(get('Block', r.parent))
  return undefined
}

function child(entity: Entity, parent: Rec | undefined, f: Record<string, unknown>): Rec {
  return {
    entity,
    uuid: newUUID(),
    f: { createdAt_: Date.now(), ...f },
    zoneName: parent?.zoneName ?? '',
    zoneOwner: parent?.zoneOwner ?? DEFAULT_OWNER,
    parent: parent?.uuid,
  }
}

// MARK: - Defter

export function createNotebook(name: string, icon: string, colorHex: string, sortIndex: number): Rec {
  const uuid = newUUID()
  const rec: Rec = {
    entity: 'Notebook', uuid,
    f: { name_: name, icon_: icon, colorHex_: colorHex, sortIndex, createdAt_: Date.now() },
    zoneName: `nb-${uuid}`, zoneOwner: DEFAULT_OWNER,
  }
  insert(rec)
  return rec
}

// MARK: - Sayfa

export function createPage(title: string, notebook: Rec, layout: PageLayout): Rec {
  const page = child('Page', notebook, {
    title_: title, layout_: layout, isPinned: false, updatedAt_: Date.now(),
    authorName_: myDisplayName(notebook),
  })
  insert(page)
  if (layout === 'document') addBlock(page, 'text')
  return page
}

/** Sayfa düzenlendi: güncelleme zamanı + son düzenleyen */
export function touch(page?: Rec) {
  if (!page) return
  const name = myDisplayName(notebookOf(page))
  update(page, { updatedAt_: Date.now(), ...(name && field(page, 'lastEditorName_') !== name ? { lastEditorName_: name } : {}) })
}

export function sortedBlocks(page?: Rec): Rec[] {
  if (!page) return []
  return Object.values(useStore.getState().recs)
    .filter((r) => r.entity === 'Block' && r.parent === page.uuid)
    .sort((a, b) => bk.order(a) - bk.order(b))
}

/** Yeni blok; `after` verilirse hemen arkasına */
export function addBlock(page: Rec, kind: BlockKind, text = '', after?: Rec | null, extra: Record<string, unknown> = {}): Rec {
  const blocks = sortedBlocks(page)
  let order: number
  const idx = after ? blocks.findIndex((b) => b.uuid === after.uuid) : -1
  if (after && idx >= 0) {
    const next = idx + 1 < blocks.length ? bk.order(blocks[idx + 1]) : bk.order(after) + 2
    order = (bk.order(after) + next) / 2
  } else {
    order = (blocks.length ? bk.order(blocks[blocks.length - 1]) : 0) + 1
  }
  const block = child('Block', page, {
    kind_: kind, text_: text, order, indent: after ? bk.indent(after) : 0,
    x: 60, y: 60, width: 280, isPlaced: false, isDone: false,
    authorName_: myDisplayName(notebookOf(page)), ...extra,
  })
  insert(block)
  touch(page)
  return block
}

/** Bloğu `target`ın önüne taşı (`target` yoksa sona) */
export function moveBlock(block: Rec, target: Rec | null) {
  const page = get('Page', block.parent)
  const others = sortedBlocks(page).filter((b) => b.uuid !== block.uuid)
  const index = target ? others.findIndex((b) => b.uuid === target.uuid) : -1
  if (!target || index < 0) {
    update(block, { order: (others.length ? bk.order(others[others.length - 1]) : 0) + 1 })
  } else {
    const previous = index > 0 ? bk.order(others[index - 1]) : bk.order(target) - 2
    update(block, { order: (previous + bk.order(target)) / 2 })
  }
  touch(page)
}

export function shiftBlock(block: Rec, delta: number) {
  const blocks = sortedBlocks(get('Page', block.parent))
  const index = blocks.findIndex((b) => b.uuid === block.uuid)
  const dest = index + delta
  if (index < 0 || dest < 0 || dest >= blocks.length) return
  if (delta < 0) moveBlock(block, blocks[dest])
  else moveBlock(block, dest + 1 < blocks.length ? blocks[dest + 1] : null)
}

/** Numaralı liste maddesinin sırası */
export function listNumber(block: Rec, blocks: Rec[]): number {
  let index = blocks.findIndex((b) => b.uuid === block.uuid)
  let n = 1
  const indent = bk.indent(block)
  while (index > 0) {
    index--
    const prev = blocks[index]
    if (bk.indent(prev) > indent) continue
    if (bk.kind(prev) !== 'numbered' || bk.indent(prev) !== indent) break
    n++
  }
  return n
}

export function insertItems(page: Rec, items: MarkdownItem[], after: Rec | null): Rec | null {
  let anchor = after
  for (const item of items) {
    const block = addBlock(page, item.kind, item.text, anchor)
    update(block, { indent: item.indent })
    if (item.isDone) setDone(block, true, 'human')
    anchor = block
  }
  return anchor
}

// MARK: - Görev

export function setDone(block: Rec, done: boolean, by: 'human' | 'ai', note?: string) {
  const name = myDisplayName(notebookOf(block))
  update(block, {
    isDone: done,
    doneBy_: done ? by : null,
    doneAt_: done ? Date.now() : null,
    doneNote_: done ? note ?? null : null,
    doneByID_: done ? me().id : null,
    doneByName_: done ? (by === 'ai' ? 'Yapay zeka' + (name ? ` (${name})` : '') : name) : null,
  })
  touch(get('Page', block.parent))
}

export function assign(block: Rec, person: Person | null) {
  update(block, {
    assigneeID_: person?.id ?? null,
    assigneeName_: person?.name ?? null,
    assignedByID_: person ? me().id : null,
    assignedByName_: person ? myDisplayName(notebookOf(block)) : null,
    assignedAt_: person ? Date.now() : null,
  })
  touch(get('Page', block.parent))
}

export function setDue(block: Rec, date: number | null) {
  update(block, { dueDate_: date })
  touch(get('Page', block.parent))
}

// MARK: - Yorum

export function addComment(block: Rec, text: string, people: Person[], byAI = false): Rec {
  const name = myDisplayName(notebookOf(block))
  const lowered = text.toLocaleLowerCase('tr')
  const mentions = people.filter((p) => !p.isMe && lowered.includes('@' + p.name.toLocaleLowerCase('tr'))).map((p) => p.id)
  const comment = child('Comment', block, {
    text_: text, authorID_: me().id,
    authorName_: byAI ? 'Yapay zeka' + (name ? ` (${name})` : '') : name ?? 'Ben',
    mentionIDs_: mentions.join(','),
  })
  insert(comment)
  touch(get('Page', block.parent))
  return comment
}

export function commentsOf(block: Rec): Rec[] {
  return Object.values(useStore.getState().recs)
    .filter((r) => r.entity === 'Comment' && r.parent === block.uuid)
    .sort((a, b) => Number(a.f.createdAt_ ?? 0) - Number(b.f.createdAt_ ?? 0))
}

// MARK: - Taşıma / silme

/** Sayfayı başka deftere taşı (bölge değişir: bulutta eski kayıtlar silinip yenisi yazılır) */
export function movePage(page: Rec, notebook: Rec) {
  const state = useStore.getState()
  const all = Object.values(state.recs)
  const blocks = all.filter((r) => r.entity === 'Block' && r.parent === page.uuid)
  const comments = all.filter((r) => r.entity === 'Comment' && blocks.some((b) => b.uuid === r.parent))
  // Eski bölgeden sil (alt kayıtlarla birlikte), yeni bölgeye yeni kayıt olarak yaz
  remove(page, { keepAssets: true })
  const reinsert = (r: Rec, parent?: string) => {
    const f = { ...r.f }
    // Varlıklar yeni kayda yeniden yüklenir
    for (const name of ['imageData_', 'drawing_']) {
      const asset = f[name] as AssetRef | undefined
      if (asset?.local) f[name] = { local: asset.local, pending: true }
    }
    insert({ ...r, zoneName: notebook.zoneName, zoneOwner: notebook.zoneOwner, parent, tag: undefined, f })
  }
  reinsert(page, notebook.uuid)
  blocks.forEach((b) => reinsert(b, b.parent))
  comments.forEach((c) => reinsert(c, c.parent))
  touch(get('Page', page.uuid))
}

export function deleteRec(rec: Rec) {
  const page = rec.entity === 'Block' ? get('Page', rec.parent) : undefined
  remove(rec)
  if (page) touch(page)
}

export function canEdit(rec?: Rec): boolean {
  if (!rec || isMine(rec)) return true
  const share = useStore.getState().shares[`${rec.zoneOwner}/${rec.zoneName}`]
  return !share || share.myPermission !== 'READ_ONLY'
}

export function isSharedWithMe(notebook: Rec) { return !isMine(notebook) }

export function isShared(notebook: Rec): boolean {
  return isSharedWithMe(notebook) || !!useStore.getState().shares[`${notebook.zoneOwner}/${notebook.zoneName}`]
}

export function participants(notebook?: Rec): Person[] {
  if (!notebook) return []
  const share = useStore.getState().shares[`${notebook.zoneOwner}/${notebook.zoneName}`]
  if (!share) return []
  return share.participants
    .filter((p) => p.owner || p.accepted)
    .map((p) => ({ id: p.isMe ? me().id : p.id, name: p.isMe ? 'Ben' : p.name, isMe: p.isMe }))
    .sort((a, b) => (a.isMe ? 0 : 1) - (b.isMe ? 0 : 1) || a.name.localeCompare(b.name, 'tr'))
}

export function imageRef(block: Rec): AssetRef | undefined {
  return block.f.imageData_ as AssetRef | undefined
}

/** Tuval kartının yaklaşık yüksekliği (otomatik dizilim için; Mac ile aynı formül) */
export function estimatedCanvasHeight(block: Rec): number {
  const kind = bk.kind(block)
  if (kind === 'divider') return 30
  const width = Number(field(block, 'width') ?? 280)
  const heading = kind === 'heading' || kind === 'heading2' || kind === 'heading3'
  const charWidth = heading ? 14 : 8.5
  const perLine = Math.max(8, (width - 24) / charWidth)
  const lines = bk.text(block).split('\n').reduce((n, l) => n + Math.max(1, Math.ceil(l.length / perLine)), 0)
  const lineHeight = heading ? 30 : 22
  if (kind === 'image') return 14 + 10 + width * 0.66 + (bk.text(block) ? 24 : 0)
  const chips = block.f.assigneeID_ || block.f.dueDate_ ? 22 : 0
  return 14 + 10 + lines * lineHeight + (heading ? 12 : 4) + chips
}
