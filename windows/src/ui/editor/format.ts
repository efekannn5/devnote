// Biçim çubuğu ⇄ odaktaki blok editörü (Mac'teki FormatState + FormatCommands)

import { create } from 'zustand'
import type { Editor } from '@tiptap/core'
import { parseInline } from '../../lib/markdown'
import { get, update } from '../../model/store'
import { bk, touch, type BlockKind } from '../../model/ops'
import { basePoint, runsToMarkdown } from './richtext'

export type InlineFormat = 'bold' | 'italic' | 'underline' | 'strikethrough' | 'code' | 'link'

export const INLINE_FORMATS: { id: InlineFormat; title: string; shortcut: string }[] = [
  { id: 'bold', title: 'Kalın', shortcut: 'Ctrl+B' },
  { id: 'italic', title: 'İtalik', shortcut: 'Ctrl+I' },
  { id: 'underline', title: 'Altı Çizili', shortcut: 'Ctrl+U' },
  { id: 'strikethrough', title: 'Üstü çizili', shortcut: 'Ctrl+Shift+X' },
  { id: 'code', title: 'Kod', shortcut: 'Ctrl+E' },
  { id: 'link', title: 'Bağlantı', shortcut: 'Ctrl+K' },
]

export const HIGHLIGHT_COLORS = [
  { hex: '#FFD60A', title: 'Sarı' }, { hex: '#30D158', title: 'Yeşil' }, { hex: '#64D2FF', title: 'Mavi' },
  { hex: '#FF6FAE', title: 'Pembe' }, { hex: '#BF5AF2', title: 'Mor' }, { hex: '#FF9F0A', title: 'Turuncu' },
]
export const TEXT_COLORS = [
  { hex: '#FF453A', title: 'Kırmızı' }, { hex: '#FF9F0A', title: 'Turuncu' }, { hex: '#30D158', title: 'Yeşil' },
  { hex: '#0A84FF', title: 'Mavi' }, { hex: '#BF5AF2', title: 'Mor' }, { hex: '#8E8E93', title: 'Gri' },
]
export const SIZE_PRESETS = [10, 12, 14, 15, 17, 20, 24, 28, 32, 40, 48, 64]
export const SIZE_RANGE: [number, number] = [8, 96]

export type FormatAction =
  | { type: 'toggle'; format: InlineFormat }
  | { type: 'highlight'; color: string | null }
  | { type: 'color'; color: string | null }
  | { type: 'size'; size: number | null }
  | { type: 'sizeStep'; delta: number }
  | { type: 'clear' }

interface FormatState {
  editor: Editor | null
  blockID: string | null
  kind: BlockKind
  bold: boolean; italic: boolean; underline: boolean; strikethrough: boolean; code: boolean; link: boolean
  pointSize: number
  /** Boyut kutusu düzenleniyor: tuvaldeki boş kutu silinmesin */
  editingToolbar: boolean
  /** Bağlantı adresi isteniyor */
  linkPrompt: { href: string } | null
}

export const useFormat = create<FormatState>(() => ({
  editor: null, blockID: null, kind: 'text',
  bold: false, italic: false, underline: false, strikethrough: false, code: false, link: false,
  pointSize: 13, editingToolbar: false, linkPrompt: null,
}))

export function publish(editor: Editor, blockID: string, kind: BlockKind) {
  const size = parseFloat(String(editor.getAttributes('textStyle').fontSize ?? ''))
  useFormat.setState({
    editor, blockID, kind,
    bold: editor.isActive('bold'), italic: editor.isActive('italic'), underline: editor.isActive('underline'),
    strikethrough: editor.isActive('strike'), code: editor.isActive('code'), link: editor.isActive('link'),
    pointSize: size || basePoint(kind),
  })
}

export function deactivate(editor: Editor) {
  setTimeout(() => {
    const s = useFormat.getState()
    if (s.editor === editor && !s.editingToolbar && !editor.isFocused) useFormat.setState({ editor: null, blockID: null })
  }, 150)
}

export function sendFormat(action: FormatAction) {
  const { editor, blockID, kind } = useFormat.getState()
  if (!editor || editor.isDestroyed) return
  const chain = editor.chain().focus()
  switch (action.type) {
    case 'toggle':
      switch (action.format) {
        case 'bold': chain.toggleBold().run(); break
        case 'italic': chain.toggleItalic().run(); break
        case 'underline': chain.toggleUnderline().run(); break
        case 'strikethrough': chain.toggleStrike().run(); break
        case 'code': chain.toggleCode().run(); break
        case 'link':
          if (editor.isActive('link')) chain.extendMarkRange('link').unsetLink().run()
          else useFormat.setState({ linkPrompt: { href: 'https://' } })
          break
      }
      break
    case 'highlight':
      if (action.color) chain.setMark('highlight', { color: action.color }).run()
      else chain.unsetMark('highlight').run()
      break
    case 'color':
      if (action.color) chain.setColor(action.color).run()
      else chain.unsetColor().run()
      break
    case 'size':
      if (action.size) chain.setFontSize(`${clampSize(action.size)}px`).run()
      else chain.unsetFontSize().run()
      break
    case 'sizeStep': {
      const current = useFormat.getState().pointSize
      chain.setFontSize(`${clampSize(current + action.delta)}px`).run()
      break
    }
    case 'clear':
      chain.unsetAllMarks().run()
      break
  }
  if (blockID) publish(editor, blockID, kind)
}

export function applyLink(href: string | null) {
  const { editor } = useFormat.getState()
  useFormat.setState({ linkPrompt: null })
  if (!editor || !href) { editor?.commands.focus(); return }
  const { empty } = editor.state.selection
  if (empty) editor.chain().focus().insertContent({ type: 'text', text: href, marks: [{ type: 'link', attrs: { href } }] }).run()
  else editor.chain().focus().extendMarkRange('link').setLink({ href }).run()
}

const clampSize = (n: number) => Math.round(Math.min(Math.max(n, SIZE_RANGE[0]), SIZE_RANGE[1]))

/** Bloğun tamamına renk / vurgu (blok menüsünden) */
export function formatWholeBlock(blockID: string, action: { type: 'color' | 'highlight'; color: string | null }) {
  const block = get('Block', blockID)
  if (!block) return
  const kind = bk.kind(block)
  const runs = parseInline(bk.text(block)).map((r) => {
    const style = { ...r.style }
    if (action.type === 'color') { if (action.color) style.color = action.color; else delete style.color }
    else { if (action.color) style.highlight = action.color; else delete style.highlight }
    return { text: r.text, style }
  })
  update(block, { text_: runsToMarkdown(runs, kind) })
  touch(get('Page', block.parent))
}
