// Mac'teki BlockOps + SlashMenuState: Enter ile bölme, ⌫ ile birleştirme, dönüştürme, yapıştırma, "/" menüsü.

import { create } from 'zustand'
import { parseInline, plainText, type MarkdownItem } from '../../lib/markdown'
import { get, update, remove, type Rec } from '../../model/store'
import {
  addBlock, bk, insertItems, moveBlock, sortedBlocks, touch, type BlockKind,
} from '../../model/ops'
import { focusBlock } from '../state'
import { runsToMarkdown } from './richtext'
import { copyImage } from './images'

export const KIND_TITLES: Record<BlockKind, string> = {
  text: 'Metin', heading: 'Başlık 1', heading2: 'Başlık 2', heading3: 'Başlık 3', checklist: 'Yapılacak',
  bullet: 'Madde işaretli liste', numbered: 'Numaralı liste', quote: 'Alıntı', code: 'Kod', divider: 'Ayırıcı', image: 'Görsel',
}
export const KIND_SHORTCUTS: Partial<Record<BlockKind, string>> = {
  heading: '#', heading2: '##', heading3: '###', checklist: '[]', bullet: '-', numbered: '1.', quote: '>', code: '```', divider: '---',
}
const KEYWORDS: Record<BlockKind, string[]> = {
  text: ['metin', 'paragraf', 'text', 'normal'], heading: ['başlık', 'h1', 'heading'], heading2: ['başlık', 'h2', 'heading'],
  heading3: ['başlık', 'h3', 'heading'], checklist: ['yapılacak', 'görev', 'todo', 'to-do', 'checkbox'],
  bullet: ['madde', 'liste', 'bullet', 'list'], numbered: ['numaralı', 'sıralı', 'liste', 'numbered', 'list'],
  quote: ['alıntı', 'quote'], code: ['kod', 'code'], divider: ['ayırıcı', 'çizgi', 'divider', 'line'],
  image: ['görsel', 'fotoğraf', 'resim', 'image', 'photo'],
}
/** "Dönüştür" menüsündeki metin türleri */
export const TEXT_KINDS: BlockKind[] = ['text', 'heading', 'heading2', 'heading3', 'checklist', 'bullet', 'numbered', 'quote', 'code']
/** "+" menüsündeki tüm türler (Notion sırası) */
export const INSERTABLE: BlockKind[] = ['text', 'heading', 'heading2', 'heading3', 'bullet', 'numbered', 'checklist', 'quote', 'code', 'divider', 'image']

export const continuesOnEnter = (k: BlockKind) => k === 'checklist' || k === 'bullet' || k === 'numbered'
export const hasText = (k: BlockKind) => k !== 'divider'

export type EditorOp =
  | { type: 'split'; tail: string }
  | { type: 'insertAbove' }
  | { type: 'paste'; items: MarkdownItem[]; cursor?: number }
  | { type: 'mergeBackward' }
  | { type: 'convert'; kind: BlockKind }
  | { type: 'focusPrevious' }
  | { type: 'focusNext' }
  | { type: 'indent'; delta: number }

/** "/" menüsünden Görsel ya da "+ Ekle → Fotoğraf": görsel seçici (PageEditor dinler) */
export const usePhotoRequest = create<{ anchor: string | null; replacing: string | null; n: number }>(() => ({ anchor: null, replacing: null, n: 0 }))
export function requestPhoto(anchor: string | null, replacing: string | null = null) {
  usePhotoRequest.setState((s) => ({ anchor, replacing, n: s.n + 1 }))
}

function blockBefore(block: Rec): Rec | undefined {
  const blocks = sortedBlocks(get('Page', block.parent))
  const i = blocks.findIndex((b) => b.uuid === block.uuid)
  return i > 0 ? blocks[i - 1] : undefined
}

function neighbor(block: Rec, step: number): Rec | undefined {
  const blocks = sortedBlocks(get('Page', block.parent))
  let i = blocks.findIndex((b) => b.uuid === block.uuid)
  if (i < 0) return undefined
  for (;;) {
    i += step
    if (i < 0 || i >= blocks.length) return undefined
    const k = bk.kind(blocks[i])
    if (hasText(k) && k !== 'image') return blocks[i]
  }
}

export function perform(op: EditorOp, blockRef: Rec) {
  const block = get('Block', blockRef.uuid)
  if (!block) return
  const page = get('Page', block.parent)
  if (!page) return
  switch (op.type) {
    case 'split': split(page, block, op.tail); break
    case 'insertAbove': {
      const kind = continuesOnEnter(bk.kind(block)) ? bk.kind(block) : 'text'
      const created = addBlock(page, kind, '', blockBefore(block) ?? null, { indent: bk.indent(block) })
      moveBlock(created, block)
      break
    }
    case 'paste': {
      const lastBlock = insertItems(page, op.items, block)
      if (lastBlock) focusBlock(lastBlock.uuid, op.cursor ?? 'end')
      break
    }
    case 'mergeBackward': mergeBackward(page, block); break
    case 'convert': convert(page, block, op.kind); break
    case 'focusPrevious': { const p = neighbor(block, -1); if (p) focusBlock(p.uuid, 'end'); break }
    case 'focusNext': { const n = neighbor(block, 1); if (n) focusBlock(n.uuid, 'start'); break }
    case 'indent':
      update(block, { indent: Math.min(Math.max(bk.indent(block) + op.delta, 0), 6) })
      touch(page)
      break
  }
}

function split(page: Rec, block: Rec, tail: string) {
  const kind = bk.kind(block)
  // Boş liste / yapılacak maddesinde Enter → önce girinti azalır, sonra normal metne döner (Notion)
  if (!bk.text(block) && !tail && kind !== 'text') {
    if (continuesOnEnter(kind) && bk.indent(block) > 0) update(block, { indent: bk.indent(block) - 1 })
    else update(block, { kind_: 'text' })
    return
  }
  const created = addBlock(page, continuesOnEnter(kind) ? kind : 'text', tail, block)
  focusBlock(created.uuid, 'start')
}

function mergeBackward(page: Rec, block: Rec) {
  // Satır başında ⌫: önce tür kalkar, sonra girinti, en son önceki satırla birleşir
  if (bk.kind(block) !== 'text') { update(block, { kind_: 'text' }); return }
  if (bk.indent(block) > 0) { update(block, { indent: bk.indent(block) - 1 }); return }
  const previous = blockBefore(block)
  if (!previous) return
  switch (bk.kind(previous)) {
    case 'divider': remove(previous); break
    case 'image': if (!bk.text(block)) remove(block); break
    default: {
      const offset = plainText(bk.text(previous)).length
      if (bk.text(block)) {
        // Markdown'ı düz birleştirmek "**a****b**" gibi bozuk sonuç verir: parçalar üzerinden birleştir
        const runs = [...parseInline(bk.text(previous)), ...parseInline(bk.text(block))]
        update(previous, { text_: runsToMarkdown(runs, bk.kind(previous)) })
      }
      remove(block)
      focusBlock(previous.uuid, offset)
    }
  }
  touch(page)
}

function convert(page: Rec, block: Rec, kind: BlockKind) {
  switch (kind) {
    case 'image': requestPhoto(block.uuid, !bk.text(block) && bk.kind(block) === 'text' ? block.uuid : null); break
    case 'divider':
      if (!bk.text(block)) {
        update(block, { kind_: 'divider' })
        const next = addBlock(page, 'text', '', block)
        focusBlock(next.uuid, 'start')
      } else {
        const divider = addBlock(page, 'divider', '', blockBefore(block) ?? null, { indent: bk.indent(block) })
        moveBlock(divider, block)
      }
      break
    default:
      update(block, { kind_: kind })
      focusBlock(block.uuid, 'end')
  }
  touch(page)
}

/** Bloğun kopyası hemen altına */
export function duplicate(block: Rec) {
  const page = get('Page', block.parent)
  if (!page) return
  const copy = addBlock(page, bk.kind(block), bk.text(block), block, { indent: bk.indent(block), width: block.f.width })
  if (bk.kind(block) === 'image') void copyImage(block, copy)
}

// MARK: - "/" menüsü

interface SlashSession { blockID: string; query: string; highlighted: number }
export const useSlash = create<{ session: SlashSession | null; picked: { blockID: string; kind: BlockKind; n: number } | null }>(() => ({ session: null, picked: null }))

export function slashResults(query: string): BlockKind[] {
  const q = query.trim().toLocaleLowerCase('tr')
  if (!q) return INSERTABLE
  return INSERTABLE.filter((k) => KIND_TITLES[k].toLocaleLowerCase('tr').includes(q) || KEYWORDS[k].some((w) => w.startsWith(q)) || KIND_SHORTCUTS[k] === q)
}

export function slashMove(delta: number) {
  const { session } = useSlash.getState()
  if (!session) return
  const n = slashResults(session.query).length
  if (!n) return
  useSlash.setState({ session: { ...session, highlighted: (session.highlighted + delta + n) % n } })
}

export function slashPick(kind: BlockKind) {
  const { session, picked } = useSlash.getState()
  if (!session) return
  useSlash.setState({ picked: { blockID: session.blockID, kind, n: (picked?.n ?? 0) + 1 } })
}

export function slashPickHighlighted() {
  const { session } = useSlash.getState()
  if (!session) return
  const results = slashResults(session.query)
  if (results[session.highlighted]) slashPick(results[session.highlighted])
}

/** Biçim çubuğundaki tür menüsünden (slash olmadan) */
export function pickKind(blockID: string, kind: BlockKind) {
  const { picked } = useSlash.getState()
  useSlash.setState({ session: null, picked: { blockID, kind, n: (picked?.n ?? 0) + 1 } })
}
