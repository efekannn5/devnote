// Bir bloğun zengin metin editörü (Mac'teki RichBlockEditor). Her blok kendi küçük editörüdür;
// Enter bölme, satır başında ⌫ birleştirme, ↑/↓ ile satırlar arası geçiş, Tab girinti, "/" menüsü,
// Markdown kısayolları ("# ", "- ", "[] " …) ve Markdown yapıştırma Mac ile aynı davranır.

import { useEffect, useRef } from 'react'
import { EditorContent, useEditor } from '@tiptap/react'
import { Extension, type Editor } from '@tiptap/core'
import { Plugin } from '@tiptap/pm/state'
import { parseBlocks } from '../../lib/markdown'
import { native } from '../../lib/native'
import { get, update, remove, type Rec } from '../../model/store'
import { bk, setDone, touch, type BlockKind } from '../../model/ops'
import { registerFocuser, useUI } from '../state'
import { docToMarkdown, extensions, fragmentRuns, runsToMarkdown, toContent } from './richtext'
import { deactivate, publish, sendFormat, useFormat } from './format'
import {
  perform, slashMove, slashPickHighlighted, useSlash, type EditorOp,
} from './blockOps'
import { addImages } from './images'

/** Ok tuşlarıyla yapılan seçim değişikliği PM'e eşzamansız (selectionchange) ulaşır; hemen arkasından
 *  basılan Enter / ⌫ eski imleci görmesin diye önce DOM'daki seçimi oku */
function syncSelection(editor: Editor) { flushView(editor.view) }
function flushView(view: unknown) {
  (view as { domObserver?: { flush?: () => void } }).domObserver?.flush?.()
}

/** Her tuştan önce (biçim kısayolları dahil) seçimi DOM'dan güncelle */
const SelectionSync = Extension.create({
  name: 'selectionSync',
  priority: 10000,
  addProseMirrorPlugins() {
    return [new Plugin({ props: { handleKeyDown: (view) => { flushView(view); return false } } })]
  },
})

const SHORTCUTS: [string, BlockKind][] = [
  ['[]', 'checklist'], ['[ ]', 'checklist'], ['###', 'heading3'], ['##', 'heading2'], ['#', 'heading'],
  ['-', 'bullet'], ['*', 'bullet'], ['>', 'quote'], ['```', 'code'], ['---', 'divider'],
]

export function placeholderFor(kind: BlockKind, documentMode: boolean): string {
  switch (kind) {
    case 'heading': return 'Başlık 1'
    case 'heading2': return 'Başlık 2'
    case 'heading3': return 'Başlık 3'
    case 'checklist': return 'Yapılacak'
    case 'bullet': case 'numbered': return 'Liste'
    case 'quote': return 'Alıntı'
    case 'code': return 'Kod'
    case 'image': return 'Açıklama ekle'
    case 'divider': return ''
    default: return documentMode ? 'Yaz ya da komutlar için “/”' : 'Yaz…'
  }
}

interface Props {
  block: Rec
  documentMode: boolean
  canEdit: boolean
  onOp?: (op: EditorOp) => void
  className?: string
}

export function BlockText({ block, documentMode, canEdit, onOp, className = '' }: Props) {
  const kind = bk.kind(block)
  const text = bk.text(block)
  // Klavye kısayolları en güncel değerleri görsün
  const ctx = useRef({ block, kind, documentMode, onOp: onOp ?? ((op: EditorOp) => perform(op, block)), canEdit, lastMarkdown: text })
  ctx.current.block = block
  ctx.current.kind = kind
  ctx.current.documentMode = documentMode
  ctx.current.onOp = onOp ?? ((op: EditorOp) => perform(op, block))
  ctx.current.canEdit = canEdit

  const keys = useRef(Extension.create({
    name: 'devnoteKeys',
    priority: 1000,
    addKeyboardShortcuts() {
      const c = ctx.current
      const slashOpen = () => useSlash.getState().session?.blockID === c.block.uuid
      return {
        Enter: ({ editor }) => {
          syncSelection(editor)
          if (slashOpen()) { slashPickHighlighted(); return true }
          if (c.documentMode && c.kind !== 'code') { splitAtCursor(editor); return true }
          return editor.commands.setHardBreak()
        },
        'Shift-Enter': ({ editor }) => editor.commands.setHardBreak(),
        'Mod-Enter': ({ editor }) => {
          // Yapılacak maddesini işaretle
          if (c.kind === 'checklist') { toggleDone(c.block); return true }
          return editor.commands.setHardBreak()
        },
        Backspace: ({ editor }) => {
          syncSelection(editor)
          const { empty, from } = editor.state.selection
          if (!empty || from !== 1 || !c.documentMode) return false
          c.onOp({ type: 'mergeBackward' })
          return true
        },
        ArrowUp: ({ editor }) => {
          if (slashOpen()) { slashMove(-1); return true }
          if (c.documentMode && editor.view.endOfTextblock('up')) { c.onOp({ type: 'focusPrevious' }); return true }
          return false
        },
        ArrowDown: ({ editor }) => {
          if (slashOpen()) { slashMove(1); return true }
          if (c.documentMode && editor.view.endOfTextblock('down')) { c.onOp({ type: 'focusNext' }); return true }
          return false
        },
        Escape: ({ editor }) => {
          if (slashOpen()) { useSlash.setState({ session: null }); return true }
          editor.commands.blur()
          return true
        },
        Tab: () => { if (!c.documentMode) return false; c.onOp({ type: 'indent', delta: 1 }); return true },
        'Shift-Tab': () => { if (!c.documentMode) return false; c.onOp({ type: 'indent', delta: -1 }); return true },
        'Mod-Shift-x': ({ editor }) => editor.commands.toggleStrike(),
        'Mod-k': () => { sendFormat({ type: 'toggle', format: 'link' }); return true },
        'Mod-Shift-h': () => { sendFormat({ type: 'highlight', color: '#FFD60A' }); return true },
        'Mod-=': () => { sendFormat({ type: 'sizeStep', delta: 2 }); return true },
        'Mod-+': () => { sendFormat({ type: 'sizeStep', delta: 2 }); return true },
        'Mod--': () => { sendFormat({ type: 'sizeStep', delta: -2 }); return true },
        'Mod-0': () => { sendFormat({ type: 'size', size: null }); return true },
        'Mod-\\': () => { sendFormat({ type: 'clear' }); return true },
      }
    },
  })).current

  /** Enter: imleçten sonrası yeni bloğa taşınır */
  function splitAtCursor(editor: Editor) {
    const c = ctx.current
    const { state } = editor
    const end = state.doc.content.size - 1
    const from = state.selection.from
    const tail = runsToMarkdown(fragmentRuns(state.doc.slice(Math.min(state.selection.to, end), end).content), c.kind)
    if (from < end || state.selection.to > from) editor.commands.deleteRange({ from, to: end })
    commit(editor)
    c.onOp({ type: 'split', tail })
  }

  function commit(editor: Editor) {
    const c = ctx.current
    const md = docToMarkdown(editor.state.doc, c.kind)
    if (md === c.lastMarkdown) return
    c.lastMarkdown = md
    const current = get('Block', c.block.uuid)
    if (!current) return
    update(current, { text_: md })
    touch(get('Page', current.parent))
  }

  function updateSlash(editor: Editor) {
    const c = ctx.current
    const plain = editor.getText({ blockSeparator: '\n' })
    const session = useSlash.getState().session
    if (c.documentMode && editor.isFocused && plain.startsWith('/') && !plain.includes('\n') && plain.length <= 25) {
      const query = plain.slice(1)
      if (session?.blockID !== c.block.uuid || session.query !== query) {
        useSlash.setState({ session: { blockID: c.block.uuid, query, highlighted: 0 } })
      }
    } else if (session?.blockID === c.block.uuid) {
      useSlash.setState({ session: null })
    }
  }

  const editor = useEditor({
    extensions: [SelectionSync, ...extensions({ placeholder: () => placeholderFor(ctx.current.kind, ctx.current.documentMode), keys })],
    content: toContent(text, kind),
    editable: canEdit,
    immediatelyRender: true,
    shouldRerenderOnTransaction: false,
    editorProps: {
      attributes: { class: 'rt', spellcheck: 'true' },
      handleTextInput(view, from, _to, input) {
        const c = ctx.current
        if (input !== ' ' || c.kind !== 'text' || !c.documentMode) return false
        const before = view.state.doc.textBetween(1, from, '\n')
        if (from !== 1 + before.length) return false
        const match = SHORTCUTS.find(([p]) => p === before)
        const numbered = /^\d{1,3}[.)]$/.test(before)
        if (!match && !numbered) return false
        const target: BlockKind = numbered ? 'numbered' : match![1]
        view.dispatch(view.state.tr.delete(1, from))
        c.onOp({ type: 'convert', kind: target })
        return true
      },
      handlePaste(_view, event) {
        const c = ctx.current
        const data = event.clipboardData
        if (!data) return false
        const files = [...data.files].filter((f) => f.type.startsWith('image/'))
        const page = get('Page', c.block.parent)
        if (files.length && page) {
          event.preventDefault()
          const empty = c.kind === 'text' && !bk.text(c.block)
          void addImages(page, files, c.block, empty ? c.block : null)
          return true
        }
        const plain = data.getData('text/plain')
        if (!plain) return false
        if (c.documentMode && c.kind !== 'code') {
          const items = parseBlocks(plain)
          if (items.length > 1 || (items.length === 1 && (items[0].kind !== 'text' || items[0].indent > 0))) {
            event.preventDefault()
            const current = get('Block', c.block.uuid)
            if (!current) return true
            const wasEmpty = bk.kind(current) === 'text' && !bk.text(current)
            c.onOp({ type: 'paste', items })
            if (wasEmpty) remove(current)
            return true
          }
        }
        if (plain.includes('\n')) {
          event.preventDefault()
          const content = plain.replace(/\r\n?/g, '\n').split('\n').flatMap((line, i) => [
            ...(i ? [{ type: 'hardBreak' }] : []), ...(line ? [{ type: 'text', text: line }] : []),
          ])
          editorRef.current?.commands.insertContent(content)
          return true
        }
        return false
      },
      handleClickOn(_view, _pos, _node, _nodePos, event) {
        const link = (event.target as HTMLElement).closest('a')
        if (link?.href && (event.ctrlKey || event.metaKey || !ctx.current.canEdit)) {
          event.preventDefault()
          void native.openURL(link.href)
          return true
        }
        return false
      },
    },
    onUpdate: ({ editor }) => {
      commit(editor)
      updateSlash(editor)
      publish(editor, ctx.current.block.uuid, ctx.current.kind)
    },
    onSelectionUpdate: ({ editor }) => { if (editor.isFocused) publish(editor, ctx.current.block.uuid, ctx.current.kind) },
    onFocus: ({ editor }) => {
      useUI.setState({ focus: ctx.current.block.uuid })
      publish(editor, ctx.current.block.uuid, ctx.current.kind)
    },
    onBlur: ({ editor }) => {
      deactivate(editor)
      const id = ctx.current.block.uuid
      if (useSlash.getState().session?.blockID === id) setTimeout(() => {
        if (!editor.isFocused && useSlash.getState().session?.blockID === id) useSlash.setState({ session: null })
      }, 200)
      setTimeout(() => {
        if (useUI.getState().focus === id && !editor.isFocused && !useFormat.getState().editingToolbar
          && !document.querySelector('.popover, .menu')) useUI.setState({ focus: null })
      }, 120)
    },
  }, [])
  const editorRef = useRef<Editor | null>(null)
  editorRef.current = editor

  // Buluttan / yapay zekadan / birleştirmeden gelen değişiklik: editörü güncelle (imleç korunur)
  useEffect(() => {
    if (!editor || editor.isDestroyed) return
    if (text === ctx.current.lastMarkdown) return
    ctx.current.lastMarkdown = text
    const { from, to } = editor.state.selection
    editor.commands.setContent(toContent(text, kind), { emitUpdate: false })
    const max = editor.state.doc.content.size - 1
    if (editor.isFocused) editor.commands.setTextSelection({ from: Math.min(from, max), to: Math.min(to, max) })
  }, [text, kind, editor])

  useEffect(() => { editor?.setEditable(canEdit, false) }, [canEdit, editor])

  // Tür değişince ipucu yenilensin
  useEffect(() => {
    if (editor && !editor.isDestroyed) editor.view.dispatch(editor.state.tr.setMeta('placeholder', kind))
  }, [kind, documentMode, editor])

  // Odak istekleri
  useEffect(() => {
    if (!editor) return
    return registerFocuser(block.uuid, (cursor) => {
      if (editor.isDestroyed || !editor.view.dom.isConnected) return false
      const max = editor.state.doc.content.size - 1
      const pos = cursor === 'start' ? 1 : cursor === 'end' ? max : Math.min(1 + cursor, max)
      // TipTap'in focus komutu odağı bir kare geciktirir; hızlı yazarken sonraki tuş kaybolmasın diye hemen
      editor.view.focus()
      editor.commands.setTextSelection(pos)
      editor.commands.scrollIntoView()
      return true
    })
  }, [editor, block.uuid])

  // "/" menüsünden ya da biçim çubuğundaki tür menüsünden seçim
  const picked = useSlash((s) => s.picked)
  useEffect(() => {
    if (!picked || picked.blockID !== block.uuid || !editor) return
    const plain = editor.getText({ blockSeparator: '\n' })
    if (plain.startsWith('/')) {
      const space = plain.indexOf(' ')
      editor.commands.deleteRange({ from: 1, to: 1 + (space < 0 ? plain.length : space) })
      commit(editor)
    }
    useSlash.setState({ session: null })
    ctx.current.onOp({ type: 'convert', kind: picked.kind })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [picked?.n])

  // Kaldırılan blok: odak / menü durumu temizlensin
  useEffect(() => () => {
    if (useSlash.getState().session?.blockID === block.uuid) useSlash.setState({ session: null })
    if (useFormat.getState().blockID === block.uuid) useFormat.setState({ editor: null, blockID: null })
  }, [block.uuid])

  return <EditorContent editor={editor} className={`content ${className}`} />
}

export function toggleDone(block: Rec) {
  const current = get('Block', block.uuid)
  if (current) setDone(current, !bk.done(current), 'human')
}
