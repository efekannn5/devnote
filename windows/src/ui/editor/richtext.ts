// Blok metni (Mac ile aynı satır içi Markdown) ⇄ TipTap/ProseMirror belgesi.
// Her blok tek paragraflık küçük bir editördür; satır sonları hardBreak olarak tutulur.

import { Extension, Mark, mergeAttributes, type JSONContent } from '@tiptap/core'
import Document from '@tiptap/extension-document'
import Paragraph from '@tiptap/extension-paragraph'
import Text from '@tiptap/extension-text'
import HardBreak from '@tiptap/extension-hard-break'
import Bold from '@tiptap/extension-bold'
import Italic from '@tiptap/extension-italic'
import Strike from '@tiptap/extension-strike'
import Code from '@tiptap/extension-code'
import Underline from '@tiptap/extension-underline'
import Link from '@tiptap/extension-link'
import { TextStyle, Color, FontSize } from '@tiptap/extension-text-style'
import { Placeholder, UndoRedo } from '@tiptap/extensions'
import type { Node as PMNode, Fragment } from '@tiptap/pm/model'
import { parseInline, serializeInline, type InlineStyle, type Run } from '../../lib/markdown'
import type { BlockKind } from '../../model/ops'

/** Mac'teki temel punto (body 13, title 22, title2 17, title3 15; kod callout 12) */
export function basePoint(kind: BlockKind): number {
  switch (kind) {
    case 'heading': return 22
    case 'heading2': return 17
    case 'heading3': return 15
    case 'code': return 12
    default: return 13
  }
}

/** Kayıtlı boyut → px (ilk sürümde ≤4 değerler orandı) */
export const points = (stored: number, base: number) => (stored <= 4 ? base * stored : stored)

/** Vurgu: Mac'te rengin %38'i (açık ve koyu temada okunur) */
const Highlight = Mark.create({
  name: 'highlight',
  addAttributes() {
    return {
      color: {
        default: null,
        parseHTML: (el) => el.getAttribute('data-color'),
        renderHTML: (attrs) => (attrs.color ? { 'data-color': attrs.color, style: `background-color: color-mix(in srgb, ${attrs.color} 38%, transparent)` } : {}),
      },
    }
  },
  parseHTML() { return [{ tag: 'mark' }] },
  renderHTML({ HTMLAttributes }) { return ['mark', mergeAttributes(HTMLAttributes), 0] },
})

/** Tek paragraflı belge */
const OneParagraph = Document.extend({ content: 'paragraph' })

export function extensions(opts: { placeholder: () => string; keys: Extension }) {
  return [
    OneParagraph, Paragraph, Text, HardBreak.configure({ keepMarks: true }),
    Bold, Italic, Strike, Code, Underline,
    Link.configure({ openOnClick: false, autolink: true, linkOnPaste: true, HTMLAttributes: { rel: 'noopener noreferrer', target: null } }),
    TextStyle, Color, FontSize, Highlight,
    UndoRedo.configure({ depth: 200 }),
    Placeholder.configure({ placeholder: opts.placeholder, showOnlyWhenEditable: false, emptyNodeClass: 'is-empty' }),
    opts.keys,
  ]
}

// MARK: - Markdown → belge

export function toContent(markdown: string, kind: BlockKind): JSONContent {
  const base = basePoint(kind)
  const content: JSONContent[] = []
  for (const run of parseInline(markdown)) {
    const marks = runMarks(run.style, base)
    const lines = run.text.split('\n')
    lines.forEach((line, i) => {
      if (i > 0) content.push({ type: 'hardBreak' })
      if (line) content.push({ type: 'text', text: line, ...(marks.length ? { marks } : {}) })
    })
  }
  return { type: 'doc', content: [{ type: 'paragraph', content }] }
}

function runMarks(s: InlineStyle, base: number) {
  const marks: { type: string; attrs?: Record<string, unknown> }[] = []
  if (s.bold) marks.push({ type: 'bold' })
  if (s.italic) marks.push({ type: 'italic' })
  if (s.strike) marks.push({ type: 'strike' })
  if (s.code) marks.push({ type: 'code' })
  if (s.underline) marks.push({ type: 'underline' })
  if (s.link) marks.push({ type: 'link', attrs: { href: s.link } })
  if (s.color || s.size) {
    marks.push({ type: 'textStyle', attrs: { color: s.color ?? null, fontSize: s.size ? `${Math.round(points(s.size, base))}px` : null } })
  }
  if (s.highlight) marks.push({ type: 'highlight', attrs: { color: s.highlight } })
  return marks
}

// MARK: - Belge → Markdown

export function fragmentRuns(fragment: Fragment | PMNode): Run[] {
  const runs: Run[] = []
  fragment.descendants((node) => {
    if (node.type.name === 'hardBreak') { runs.push({ text: '\n', style: last(runs)?.style ?? {} }); return false }
    if (!node.isText) return true
    const style: InlineStyle = {}
    for (const mark of node.marks) {
      switch (mark.type.name) {
        case 'bold': style.bold = true; break
        case 'italic': style.italic = true; break
        case 'strike': style.strike = true; break
        case 'code': style.code = true; break
        case 'underline': style.underline = true; break
        case 'link': if (mark.attrs.href) style.link = mark.attrs.href; break
        case 'highlight': if (mark.attrs.color) style.highlight = String(mark.attrs.color).toUpperCase(); break
        case 'textStyle': {
          if (mark.attrs.color) style.color = normalizeColor(String(mark.attrs.color))
          const size = parseFloat(String(mark.attrs.fontSize ?? ''))
          if (size) style.size = Math.round(size)
        }
      }
    }
    runs.push({ text: node.text ?? '', style })
    return false
  })
  return runs
}

const last = <T,>(a: T[]) => a[a.length - 1]

function normalizeColor(c: string): string {
  if (c.startsWith('#')) return c.toUpperCase()
  const m = c.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/)
  if (!m) return c
  return '#' + [m[1], m[2], m[3]].map((v) => Number(v).toString(16).padStart(2, '0')).join('').toUpperCase()
}

/** Satır sonu biçimsiz yazılsın (Markdown'da biçim işaretleri satırı aşmasın) */
export function runsToMarkdown(runs: Run[], kind: BlockKind): string {
  const base = basePoint(kind)
  const cleaned = runs.map((r) => {
    if (r.text === '\n') return { text: '\n', style: {} }
    // Bloğun normal boyutundaki "boyut" biçimi gereksiz
    if (r.style.size && Math.abs(r.style.size - base) < 0.5) { const { size: _, ...rest } = r.style; return { text: r.text, style: rest } }
    return r
  })
  return serializeInline(cleaned)
}

export const docToMarkdown = (doc: PMNode, kind: BlockKind) => runsToMarkdown(fragmentRuns(doc), kind)
