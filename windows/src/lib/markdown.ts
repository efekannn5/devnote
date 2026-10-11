// Mac / iPhone ile aynı metin biçimi: satır içi Markdown + Apple'ın özel öznitelikleri
//   **kalın**  *italik*  ~~üstü çizili~~  `kod`  [bağlantı](url)
//   ^[metin](highlight: '#FFD60A', color: '#FF453A', underline: true, size: 24)
// Blok türleri (başlık, liste…) metinde değil, bloğun `kind_` alanında durur.

export interface InlineStyle {
  bold?: boolean
  italic?: boolean
  strike?: boolean
  code?: boolean
  underline?: boolean
  link?: string
  highlight?: string
  color?: string
  /** punto (px). Eski sürümlerde ≤4 değerler orandı. */
  size?: number
}

export interface Run {
  text: string
  style: InlineStyle
}

// MARK: - Ayrıştırma

/** Satır içi Markdown → biçimli parçalar */
export function parseInline(markdown: string): Run[] {
  const runs: Run[] = []
  parseInto(markdown, {}, runs)
  return mergeRuns(runs)
}

function push(runs: Run[], text: string, style: InlineStyle) {
  if (!text) return
  runs.push({ text, style: { ...style } })
}

/** Kapanış işaretini bul (kaçışları ve iç içe `kod` parçalarını atlayarak) */
function findClosing(src: string, from: number, marker: string): number {
  let i = from
  while (i < src.length) {
    const ch = src[i]
    if (ch === '\\') { i += 2; continue }
    if (ch === '`' && marker !== '`') {
      const end = src.indexOf('`', i + 1)
      if (end === -1) return -1
      i = end + 1
      continue
    }
    if (src.startsWith(marker, i)) {
      // ** içinde * kapanışı karışmasın: *** gibi durumlarda en dıştakini bul
      if (marker === '*' && src[i + 1] === '*') {
        const inner = findClosing(src, i + 2, '**')
        if (inner === -1) return -1
        i = inner + 2
        continue
      }
      return i
    }
    i++
  }
  return -1
}

/** [ ile başlayan köşeli parantezin kapanışı (iç içe köşeli parantezleri sayar) */
function findBracket(src: string, open: number): number {
  let depth = 0
  for (let i = open; i < src.length; i++) {
    const ch = src[i]
    if (ch === '\\') { i++; continue }
    if (ch === '`') {
      const end = src.indexOf('`', i + 1)
      if (end === -1) return -1
      i = end
      continue
    }
    if (ch === '[') depth++
    else if (ch === ']') { depth--; if (depth === 0) return i }
  }
  return -1
}

function findParen(src: string, open: number): number {
  let depth = 0
  let quote: string | null = null
  for (let i = open; i < src.length; i++) {
    const ch = src[i]
    if (quote) { if (ch === '\\') i++; else if (ch === quote) quote = null; continue }
    if (ch === "'" || ch === '"') { quote = ch; continue }
    if (ch === '(') depth++
    else if (ch === ')') { depth--; if (depth === 0) return i }
  }
  return -1
}

/** `highlight: '#FFD60A', size: 24, underline: true` → öznitelikler */
export function parseAttributes(src: string): Partial<InlineStyle> {
  const out: Partial<InlineStyle> = {}
  const re = /([A-Za-z]+)\s*:\s*('([^']*)'|"([^"]*)"|[^,\s}]+)/g
  let m: RegExpExecArray | null
  while ((m = re.exec(src))) {
    const key = m[1]
    const raw = m[3] ?? m[4] ?? m[2]
    switch (key) {
      case 'highlight': out.highlight = raw; break
      case 'color': out.color = raw; break
      case 'underline': out.underline = raw === 'true'; break
      case 'size': { const n = Number(raw); if (!Number.isNaN(n)) out.size = n; break }
    }
  }
  return out
}

function parseInto(src: string, style: InlineStyle, runs: Run[]) {
  let buf = ''
  let i = 0
  const flush = () => { push(runs, buf, style); buf = '' }
  while (i < src.length) {
    const ch = src[i]
    if (ch === '\\' && i + 1 < src.length && /[\\*_`[\]~^()#>+\-.!{}|]/.test(src[i + 1])) {
      buf += src[i + 1]; i += 2; continue
    }
    if (ch === '`') {
      const end = src.indexOf('`', i + 1)
      if (end > i) {
        flush()
        push(runs, src.slice(i + 1, end), { ...style, code: true })
        i = end + 1
        continue
      }
    }
    if (src.startsWith('~~', i)) {
      const end = findClosing(src, i + 2, '~~')
      if (end > i + 2) {
        flush(); parseInto(src.slice(i + 2, end), { ...style, strike: true }, runs); i = end + 2; continue
      }
    }
    if (src.startsWith('***', i)) {
      const end = src.indexOf('***', i + 3)
      if (end > i + 3) {
        flush(); parseInto(src.slice(i + 3, end), { ...style, bold: true, italic: true }, runs); i = end + 3; continue
      }
    }
    if (src.startsWith('**', i) || src.startsWith('__', i)) {
      const marker = src.slice(i, i + 2)
      const end = findClosing(src, i + 2, marker)
      if (end > i + 2 && !/\s/.test(src[i + 2])) {
        flush(); parseInto(src.slice(i + 2, end), { ...style, bold: true }, runs); i = end + 2; continue
      }
    }
    if ((ch === '*' || ch === '_') && i + 1 < src.length && !/\s/.test(src[i + 1])) {
      // _ kelime içinde italik değildir (CommonMark)
      const wordInside = ch === '_' && i > 0 && /[\p{L}\p{N}]/u.test(src[i - 1])
      if (!wordInside) {
        const end = findClosing(src, i + 1, ch)
        if (end > i + 1 && !/\s/.test(src[end - 1])) {
          flush(); parseInto(src.slice(i + 1, end), { ...style, italic: true }, runs); i = end + 1; continue
        }
      }
    }
    if ((ch === '[' || (ch === '^' && src[i + 1] === '[')) ) {
      const open = ch === '^' ? i + 1 : i
      const close = findBracket(src, open)
      if (close > open && src[close + 1] === '(') {
        const pclose = findParen(src, close + 1)
        if (pclose > close) {
          const inner = src.slice(open + 1, close)
          const target = src.slice(close + 2, pclose).trim()
          flush()
          if (ch === '^') {
            parseInto(inner, { ...style, ...parseAttributes(target) }, runs)
          } else {
            const url = target.startsWith('<') && target.endsWith('>') ? target.slice(1, -1) : target.split(/\s+/)[0]
            parseInto(inner, { ...style, link: url }, runs)
          }
          i = pclose + 1
          continue
        }
      }
    }
    buf += ch
    i++
  }
  flush()
}

function sameStyle(a: InlineStyle, b: InlineStyle): boolean {
  return !!a.bold === !!b.bold && !!a.italic === !!b.italic && !!a.strike === !!b.strike &&
    !!a.code === !!b.code && !!a.underline === !!b.underline && (a.link ?? '') === (b.link ?? '') &&
    (a.highlight ?? '') === (b.highlight ?? '') && (a.color ?? '') === (b.color ?? '') &&
    (a.size ?? 0) === (b.size ?? 0)
}

function mergeRuns(runs: Run[]): Run[] {
  const out: Run[] = []
  for (const run of runs) {
    const last = out[out.length - 1]
    if (last && sameStyle(last.style, run.style)) last.text += run.text
    else out.push({ text: run.text, style: run.style })
  }
  return out
}

/** Biçimsiz düz metin (liste önizlemesi, arama) */
export function plainText(markdown: string): string {
  return parseInline(markdown).map((r) => r.text).join('')
}

export function hasMarkup(text: string): boolean {
  return /(\*\*|__|~~|`|\*[^\s*]|_[^\s_]|\[[^\]]*\]\(|\^\[)/.test(text)
}

// MARK: - Yazma (Mac'teki RichText.markdown ile aynı kurallar)

export function escape(text: string): string {
  let out = ''
  for (const ch of text) {
    if ('\\*_`[]~^'.includes(ch)) out += '\\'
    out += ch
  }
  return out
}

function isPlain(s: InlineStyle): boolean {
  return !s.bold && !s.italic && !s.strike && !s.code && !s.underline && !s.link && !s.highlight && !s.color && !s.size
}

function wrap(text: string, style: InlineStyle): string {
  if (isPlain(style)) return escape(text)
  // İşaretler boşluğa yapışırsa Markdown biçimi tanımaz: baştaki / sondaki boşluklar dışarıda kalsın
  const core = text.replace(/^ +| +$/g, '')
  if (!core) return text
  const lead = text.match(/^ */)![0]
  const trail = text.match(/ *$/)![0]
  let s = style.code ? '`' + core + '`' : escape(core)
  if (style.strike) s = `~~${s}~~`
  if (style.italic) s = `*${s}*`
  if (style.bold) s = `**${s}**`
  if (style.link) {
    const url = style.link
    s = `[${s}](${url.includes(' ') || url.includes(')') ? `<${url}>` : url})`
  }
  const attrs: string[] = []
  if (style.highlight) attrs.push(`highlight: '${style.highlight}'`)
  if (style.color) attrs.push(`color: '${style.color}'`)
  if (style.underline) attrs.push('underline: true')
  if (style.size) attrs.push(`size: ${Math.round(style.size)}`)
  if (attrs.length) s = `^[${s}](${attrs.join(', ')})`
  return lead + s + trail
}

/** Biçimli parçalar → Markdown. Satır sonları (kod / tuval) aynen kalır. */
export function serializeInline(runs: Run[]): string {
  const merged = mergeRuns(runs.filter((r) => r.text.length > 0))
  // Satır sonu biçimin içinde kalırsa Markdown bozulur: her satırı ayrı sar
  return merged
    .map((r) => r.text.split('\n').map((line) => wrap(line, r.style)).join('\n'))
    .join('')
}

// MARK: - Bloklar (yapıştırma, yapay zeka)

export type BlockKind =
  | 'text' | 'heading' | 'heading2' | 'heading3' | 'checklist' | 'bullet' | 'numbered'
  | 'quote' | 'code' | 'divider' | 'image'

export interface MarkdownItem {
  kind: BlockKind
  text: string
  indent: number
  isDone: boolean
}

/** Mac'teki MarkdownBlocks.parse ile aynı */
export function parseBlocks(markdown: string): MarkdownItem[] {
  const items: MarkdownItem[] = []
  let code: string[] | null = null
  for (const raw of markdown.replace(/\r\n/g, '\n').split('\n')) {
    const trimmed = raw.trim()
    if (trimmed.startsWith('```')) {
      if (code) { items.push({ kind: 'code', text: code.join('\n'), indent: 0, isDone: false }); code = null }
      else code = []
      continue
    }
    if (code) { code.push(raw); continue }
    if (!trimmed) continue
    const leading = raw.match(/^[ \t]*/)![0]
    const width = [...leading].reduce((n, c) => n + (c === '\t' ? 2 : 1), 0)
    items.push(blockItem(trimmed, Math.min(6, Math.floor(width / 2))))
  }
  if (code && code.length) items.push({ kind: 'code', text: code.join('\n'), indent: 0, isDone: false })
  return items
}

export function blockItem(line: string, indent = 0): MarkdownItem {
  const rest = (n: number) => line.slice(n).trim()
  const lower = line.toLowerCase()
  const item = (kind: BlockKind, text: string, ind = indent, isDone = false): MarkdownItem => ({ kind, text, indent: ind, isDone })
  if (['---', '***', '___'].includes(line.replace(/ /g, ''))) return item('divider', '', 0)
  if (lower.startsWith('- [x] ') || lower.startsWith('* [x] ')) return item('checklist', rest(6), indent, true)
  if (line.startsWith('- [ ] ') || line.startsWith('* [ ] ')) return item('checklist', rest(6))
  if (line.startsWith('[] ')) return item('checklist', rest(3))
  if (line.startsWith('### ')) return item('heading3', rest(4), 0)
  if (line.startsWith('## ')) return item('heading2', rest(3), 0)
  if (line.startsWith('# ')) return item('heading', rest(2), 0)
  if (line.startsWith('#### ')) return item('heading3', rest(5), 0)
  if (line.startsWith('- ') || line.startsWith('* ') || line.startsWith('• ')) return item('bullet', rest(2))
  const numbered = line.match(/^\d{1,3}[.)] /)
  if (numbered) return item('numbered', rest(numbered[0].length))
  if (line.startsWith('> ')) return item('quote', rest(2), 0)
  return item('text', line)
}
