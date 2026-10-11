// Mac'teki MCPTools'un birebir karşılığı: initialize, ping, tools/list, tools/call (aynı araçlar, aynı metinler).
// İstekler Rust'taki yerel sunucudan (127.0.0.1) olay olarak gelir; yanıt mcp_respond ile döner.

import { create } from 'zustand'
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { isTauri } from '../lib/native'
import { report } from '../lib/errors'
import { useSettings } from '../lib/settings'
import { parseBlocks } from '../lib/markdown'
import { get, remove, useStore, update, type Person, type Rec } from '../model/store'
import {
  addBlock, addComment, assign, bk, canEdit, commentsOf, createNotebook, createPage, isShared, listNumber, me, nb,
  notebookOf, participants, pg, setDone, setDue, sortedBlocks, type PageLayout,
} from '../model/ops'

interface McpState { running: boolean; lastActivity: string | null; error: string | null }
export const useMcp = create<McpState>(() => ({ running: false, lastActivity: null, error: null }))
const activity = (text: string) => useMcp.setState({ lastActivity: text })

const SUPPORTED = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05']

let unlisten: (() => void) | null = null

export async function startMcp() {
  if (!isTauri) return
  const { mcpEnabled, mcpPort } = useSettings.getState()
  if (!unlisten) {
    unlisten = await listen<{ id: number; body: string }>('mcp-request', (event) => {
      const { id, body } = event.payload
      let reply: string | null = null
      try {
        const result = handle(JSON.parse(body))
        reply = result == null ? null : JSON.stringify(result)
      } catch {
        reply = JSON.stringify(rpcError(null, -32700, 'Parse error'))
      }
      void invoke('mcp_respond', { id, reply })
    })
  }
  if (!mcpEnabled) { await stopMcp(); return }
  try {
    await invoke('mcp_start', { port: mcpPort })
    useMcp.setState({ running: true, error: null })
  } catch (error) {
    useMcp.setState({ running: false, error: String(error) })
    report('MCP', error)
  }
}

export async function stopMcp() {
  if (!isTauri) return
  await invoke('mcp_stop')
  useMcp.setState({ running: false })
}

// MARK: - JSON-RPC

type Json = Record<string, unknown>

function handle(message: unknown): unknown {
  if (Array.isArray(message)) {
    const replies = message.map(handleOne).filter((r) => r != null)
    return replies.length ? replies : null
  }
  return handleOne(message)
}

function handleOne(message: unknown): unknown {
  if (!message || typeof message !== 'object') return rpcError(null, -32600, 'Invalid Request')
  const msg = message as Json
  const method = msg.method as string | undefined
  if (!method) return null
  if (!('id' in msg)) return null
  const id = msg.id
  const params = (msg.params as Json) ?? {}
  switch (method) {
    case 'initialize': {
      const requested = String(params.protocolVersion ?? '')
      const client = ((params.clientInfo as Json)?.name as string) ?? 'istemci'
      activity(`${client} bağlandı`)
      return rpcResult(id, {
        protocolVersion: SUPPORTED.includes(requested) ? requested : SUPPORTED[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'devnote', title: 'DevNote', version: '0.1.0' },
        instructions: INSTRUCTIONS,
      })
    }
    case 'ping': return rpcResult(id, {})
    case 'tools/list': return rpcResult(id, { tools: TOOLS })
    case 'tools/call': {
      const name = String(params.name ?? '')
      const args = (params.arguments as Json) ?? {}
      try {
        const text = call(name, args)
        return rpcResult(id, { content: [{ type: 'text', text }], isError: false })
      } catch (error) {
        const text = error instanceof Error ? error.message : String(error)
        report('MCP aracı', `${name}: ${text}`, { silent: true })
        return rpcResult(id, { content: [{ type: 'text', text }], isError: true })
      }
    }
    default: return rpcError(id, -32601, `Method not found: ${method}`)
  }
}

const rpcResult = (id: unknown, result: Json) => ({ jsonrpc: '2.0', id, result })
const rpcError = (id: unknown, code: number, message: string) => ({ jsonrpc: '2.0', id: id ?? null, error: { code, message } })

class ToolError extends Error {}

// MARK: - Araçlar

const all = (entity: Rec['entity']) => Object.values(useStore.getState().recs).filter((r) => r.entity === entity)
const pagesOf = (notebook: Rec) => all('Page').filter((p) => p.parent === notebook.uuid)
const tasksOf = (page: Rec) => sortedBlocks(page).filter((b) => bk.kind(b) === 'checklist')
const openCount = (page: Rec) => tasksOf(page).filter((b) => !bk.done(b)).length
const short = (uuid: string) => uuid.toLowerCase().slice(0, 8)
const title = (p: Rec) => pg.title(p) || 'Başlıksız'
const fmtDate = (ms: number) => new Date(ms).toLocaleString('tr-TR', { dateStyle: 'medium', timeStyle: 'short' })
const contains = (text: string, q: string) => text.toLocaleLowerCase('tr').includes(q.toLocaleLowerCase('tr'))

function str(a: Json, key: string): string {
  const v = a[key]
  if (typeof v !== 'string' || !v) throw new ToolError(`'${key}' parametresi gerekli.`)
  return v
}

function meta(b: Rec): string {
  const parts: string[] = []
  if (b.f.assigneeName_) parts.push(`atanan: ${b.f.assigneeName_}`)
  if (b.f.dueDate_) parts.push(`son tarih: ${fmtDate(Number(b.f.dueDate_))}`)
  return parts.length ? ', ' + parts.join(', ') : ''
}

function unique<T>(items: T[], what: string, key: string): T {
  if (items.length === 1) return items[0]
  throw new ToolError(items.length === 0 ? `${what} bulunamadı: ${key}` : `${what} belirsiz, daha uzun bir id ver: ${key}`)
}
const matchesID = (uuid: string, key: string) => key.length >= 4 && uuid.toLowerCase().startsWith(key.toLowerCase())

const block = (key: string) => unique(all('Block').filter((b) => matchesID(b.uuid, key)), 'Görev', key)
function page(key: string): Rec {
  const pages = all('Page')
  const byID = pages.filter((p) => matchesID(p.uuid, key))
  if (byID.length) return unique(byID, 'Sayfa', key)
  return unique(pages.filter((p) => pg.title(p).toLocaleLowerCase('tr') === key.toLocaleLowerCase('tr')), 'Sayfa', key)
}
function notebook(key: string): Rec {
  const nbs = all('Notebook')
  const byID = nbs.filter((n) => matchesID(n.uuid, key))
  if (byID.length) return unique(byID, 'Defter', key)
  return unique(nbs.filter((n) => nb.name(n).toLocaleLowerCase('tr') === key.toLocaleLowerCase('tr')), 'Defter', key)
}

interface Member { person: Person; isOwner: boolean; canEdit: boolean; accepted: boolean }
export function teamMembers(notebook: Rec): Member[] {
  const share = useStore.getState().shares[`${notebook.zoneOwner}/${notebook.zoneName}`]
  const mine = me()
  if (!share) return [{ person: mine, isOwner: true, canEdit: true, accepted: true }]
  return share.participants
    .filter((p) => p.id)
    .map((p) => ({
      person: { id: p.isMe ? mine.id : p.id, name: p.isMe ? 'Ben' : p.name, isMe: p.isMe },
      isOwner: p.owner, canEdit: p.permission === 'READ_WRITE', accepted: p.accepted || p.owner,
    }))
    .sort((a, b) => Number(!a.isOwner) - Number(!b.isOwner) || Number(!a.person.isMe) - Number(!b.person.isMe) || a.person.name.localeCompare(b.person.name, 'tr'))
}

function person(key: string, inNotebook: Rec | null): Person | null {
  const mine = me()
  if (['me', 'ben', 'bana', 'kullanıcı', 'user'].includes(key.toLocaleLowerCase('tr'))) return mine
  const notebooks = inNotebook ? [inNotebook] : all('Notebook')
  const known: Person[] = notebooks.flatMap(pagesOf).flatMap(tasksOf)
    .filter((b) => b.f.assigneeID_)
    .map((b) => ({ id: String(b.f.assigneeID_), name: String(b.f.assigneeName_ ?? b.f.assigneeID_), isMe: b.f.assigneeID_ === mine.id }))
  const people = [...notebooks.flatMap(teamMembers).filter((m) => m.accepted).map((m) => m.person), ...known]
  const matches = new Map<string, Person>()
  for (const p of people) if (contains(p.name, key) && !matches.has(p.id)) matches.set(p.id, p)
  if (matches.size > 1) throw new ToolError(`Birden çok kişi eşleşti: ${[...matches.values()].map((p) => p.name).join(', ')}`)
  return [...matches.values()][0] ?? null
}

function render(p: Rec): string {
  const notebookName = nb.name(get('Notebook', p.parent))
  const out = [`# ${title(p)}`, `page_id: ${short(p.uuid)} · defter: ${notebookName || '-'} · görünüm: ${pg.layout(p) === 'canvas' ? 'Tuval' : 'Belge'}`, '']
  const blocks = sortedBlocks(p)
  for (const b of blocks) {
    const kind = bk.kind(b)
    const text = bk.text(b)
    if (!text && kind !== 'image' && kind !== 'divider') continue
    const pad = '  '.repeat(bk.indent(b))
    const m = meta(b)
    let line: string
    switch (kind) {
      case 'heading': line = `## ${text}`; break
      case 'heading2': line = `### ${text}`; break
      case 'heading3': line = `#### ${text}`; break
      case 'checklist':
        line = `- [${bk.done(b) ? 'x' : ' '}] ${text}` + (b.f.doneBy_ === 'ai' ? ` _(AI: ${b.f.doneNote_ ?? 'tamamladı'})_` : '') + (m ? ` _(${m.slice(2)})_` : '')
        break
      case 'bullet': line = `- ${text}`; break
      case 'numbered': line = `${listNumber(b, blocks)}. ${text}`; break
      case 'quote': line = `> ${text}`; break
      case 'code': line = '```\n' + text + '\n```'; break
      case 'divider': line = '---'; break
      case 'image': line = `![${text || 'görsel'}](görsel)`; break
      default: line = text
    }
    out.push(`${pad}${line}  <!-- id: ${short(b.uuid)} -->`)
    for (const c of commentsOf(b)) out.push(`${pad}    > 💬 ${c.f.authorName_} (${fmtDate(Number(c.f.createdAt_))}): ${c.f.text_}`)
  }
  return out.join('\n')
}

function insertMarkdown(md: string, p: Rec) {
  for (const item of parseBlocks(md)) {
    const b = addBlock(p, item.kind, item.text)
    update(b, { indent: item.indent })
    if (item.isDone) setDone(b, true, 'ai')
  }
}

function call(name: string, a: Json): string {
  switch (name) {
    case 'list_notebooks': {
      const nbs = all('Notebook')
      if (!nbs.length) return 'Hiç defter yok.'
      return nbs.map((n) => {
        const pages = pagesOf(n)
        const open = pages.reduce((s, p) => s + openCount(p), 0)
        return `- ${nb.name(n)} (id: ${short(n.uuid)}, ${pages.length} sayfa, ${open} açık görev${isShared(n) ? ', paylaşılan' : ''})`
      }).join('\n')
    }
    case 'list_pages': {
      let pages = all('Page')
      if (typeof a.notebook === 'string') { const n = notebook(a.notebook); pages = pages.filter((p) => p.parent === n.uuid) }
      if (!pages.length) return 'Sayfa bulunamadı.'
      return pages.map((p) => {
        const t = tasksOf(p)
        return `- "${title(p)}" (page_id: ${short(p.uuid)}, defter: ${nb.name(get('Notebook', p.parent)) || '-'}, görevler: ${t.length - openCount(p)}/${t.length})`
      }).join('\n')
    }
    case 'read_page': return render(page(str(a, 'page')))
    case 'list_open_tasks': {
      let pages = all('Page')
      if (typeof a.notebook === 'string') { const n = notebook(a.notebook); pages = pages.filter((p) => p.parent === n.uuid) }
      if (typeof a.page === 'string') pages = [page(a.page)]
      let assignee: string | null = null
      if (typeof a.assignee === 'string' && a.assignee) {
        const target = person(a.assignee, null)
        if (!target) throw new ToolError(`Kişi bulunamadı: ${a.assignee}`)
        assignee = target.id
      }
      const lines = pages.flatMap((p) => tasksOf(p)
        .filter((b) => !bk.done(b) && (!assignee || b.f.assigneeID_ === assignee))
        .map((b) => `- [ ] ${bk.text(b)}  (task_id: ${short(b.uuid)}, sayfa: "${title(p)}", defter: ${nb.name(get('Notebook', p.parent)) || '-'}${meta(b)})`))
      return lines.length ? lines.join('\n') : 'Açık görev yok. 🎉'
    }
    case 'list_people': {
      const nbs = typeof a.notebook === 'string' ? [notebook(a.notebook)] : all('Notebook').filter(isShared)
      if (!nbs.length) return 'Paylaşılan defter yok. Görev atamak için önce defteri uygulamadan paylaş.'
      return nbs.map((n) => {
        const open = pagesOf(n).flatMap(tasksOf).filter((b) => !bk.done(b))
        const lines = teamMembers(n).map((m) => {
          const count = open.filter((b) => b.f.assigneeID_ === m.person.id).length
          const flags = [m.isOwner ? 'sahip' : null, m.canEdit ? null : 'salt okunur', m.accepted ? null : 'davet bekliyor'].filter(Boolean).join(', ')
          return `  - ${m.person.isMe ? 'Ben (kullanıcı)' : m.person.name}${flags ? ` [${flags}]` : ''} — ${count} açık görev`
        })
        return [`${nb.name(n)}:`, ...lines].join('\n')
      }).join('\n')
    }
    case 'assign_task': {
      const task = block(str(a, 'task_id'))
      if (bk.kind(task) !== 'checklist') throw new ToolError('Bu blok bir yapılacak maddesi değil.')
      if (!canEdit(task)) throw new ToolError('Bu defterde düzenleme yetkin yok.')
      const who = typeof a.person === 'string' ? a.person : ''
      if (!who) { assign(task, null); return `Atama kaldırıldı: ${bk.text(task)}` }
      const target = person(who, notebookOf(task) ?? null)
      if (!target) throw new ToolError(`Kişi bulunamadı: ${who}`)
      assign(task, target)
      activity(`→ ${target.name}: ${bk.text(task)}`)
      return `${target.isMe ? 'Kullanıcıya' : target.name + ' kişisine'} atandı: ${bk.text(task)}`
    }
    case 'set_due_date': {
      const task = block(str(a, 'task_id'))
      const raw = typeof a.due === 'string' ? a.due : ''
      if (!raw) { setDue(task, null); return `Son tarih kaldırıldı: ${bk.text(task)}` }
      const date = Date.parse(raw)
      if (Number.isNaN(date)) throw new ToolError('Tarih ISO 8601 olmalı, ör. 2026-10-12T17:00:00+03:00')
      setDue(task, date)
      return `Son tarih: ${fmtDate(date)} — ${bk.text(task)}`
    }
    case 'list_comments': {
      const task = block(str(a, 'task_id'))
      const comments = commentsOf(task)
      if (!comments.length) return `Yorum yok: ${bk.text(task)}`
      return [`Yorumlar — ${bk.text(task)}:`, ...comments.map((c) => `- ${c.f.authorName_} (${fmtDate(Number(c.f.createdAt_))}): ${c.f.text_}`)].join('\n')
    }
    case 'add_comment': {
      const task = block(str(a, 'task_id'))
      if (!canEdit(task)) throw new ToolError('Bu defterde düzenleme yetkin yok.')
      const text = str(a, 'text').trim()
      if (!text) throw new ToolError('Yorum boş olamaz.')
      addComment(task, text, participants(notebookOf(task)), true)
      activity(`💬 ${bk.text(task)}`)
      return `Yorum eklendi: ${bk.text(task)}`
    }
    case 'complete_task': {
      const task = block(str(a, 'task_id'))
      if (bk.kind(task) !== 'checklist') throw new ToolError('Bu blok bir yapılacak maddesi değil.')
      if (bk.done(task)) return `Zaten tamamlanmış: ${bk.text(task)}`
      setDone(task, true, 'ai', typeof a.note === 'string' ? a.note : undefined)
      activity(`✓ ${bk.text(task)}`)
      return `Tamamlandı olarak işaretlendi: ${bk.text(task)}`
    }
    case 'reopen_task': {
      const task = block(str(a, 'task_id'))
      if (bk.kind(task) !== 'checklist') throw new ToolError('Bu blok bir yapılacak maddesi değil.')
      setDone(task, false, 'ai')
      activity(`↺ ${bk.text(task)}`)
      return `Yeniden açıldı: ${bk.text(task)}`
    }
    case 'add_task': {
      const p = page(str(a, 'page'))
      const after = typeof a.after_task_id === 'string' ? block(a.after_task_id) : null
      const task = addBlock(p, 'checklist', str(a, 'text'), after)
      activity(`+ ${bk.text(task)}`)
      return `Eklendi (task_id: ${short(task.uuid)}): ${bk.text(task)}`
    }
    case 'create_page': {
      const nbName = str(a, 'notebook')
      let n: Rec
      try { n = notebook(nbName) } catch { n = createNotebook(nbName, 'book.closed.fill', '#0A84FF', all('Notebook').length) }
      const layout: PageLayout = a.layout === 'canvas' ? 'canvas' : 'document'
      const p = createPage(str(a, 'title'), n, layout)
      // Belge sayfası boş bir metin satırıyla başlar; içerik verildiyse onu kaldır
      const content = typeof a.content === 'string' ? a.content : ''
      if (content) {
        const first = sortedBlocks(p)[0]
        insertMarkdown(content, p)
        if (first && !bk.text(first)) remove(first)
      }
      activity(`Yeni sayfa: ${pg.title(p)}`)
      return `Oluşturuldu (page_id: ${short(p.uuid)}).\n\n` + render(get('Page', p.uuid)!)
    }
    case 'append_to_page': {
      const p = page(str(a, 'page'))
      insertMarkdown(str(a, 'content'), p)
      activity(`Not eklendi: ${title(p)}`)
      return render(p)
    }
    case 'search': {
      const q = str(a, 'query')
      const hits = all('Page').filter((p) => contains(pg.title(p), q) || sortedBlocks(p).some((b) => contains(bk.text(b), q)))
      if (!hits.length) return 'Sonuç yok.'
      return hits.map((p) => {
        const matches = sortedBlocks(p).filter((b) => contains(bk.text(b), q)).slice(0, 3).map((b) => `    · ${bk.text(b)} (id: ${short(b.uuid)})`)
        return [`- "${title(p)}" (page_id: ${short(p.uuid)})`, ...matches].join('\n')
      }).join('\n')
    }
    default: throw new ToolError(`Bilinmeyen araç: ${name}`)
  }
}


// MARK: - Tanımlar

const INSTRUCTIONS = `DevNote kullanıcının not uygulamasıdır. Sayfalardaki yapılacak (checklist) maddeleri kullanıcının senden beklediği işlerdir. Akış: list_open_tasks ile açık görevleri gör, işi gerçekten yap ve doğrula, sonra complete_task ile kısa bir açıklama (note) bırakarak işaretle. Doğrulamadığın bir maddeyi asla tamamlandı olarak işaretleme. id'ler 8 karakterlik kısa id olarak verilir.
Ekip: paylaşılan defterlerde görevler kişilere atanır. Kullanıcının kendi işleri için list_open_tasks(assignee: "me") kullan; başkasına atanmış görevi kullanıcı açıkça istemedikçe tamamlama. Kişileri list_people ile gör, assign_task ve set_due_date ile ata ve süre ver. Görevin yorumlarını list_comments ile oku; ilerleme ya da soru için add_comment kullan. Satır içi biçim Markdown: **kalın**, *italik*, ~~üstü çizili~~, \`kod\`, [bağlantı](url), ^[vurgulu](highlight: '#FFD60A'), ^[renkli](color: '#FF453A'), ^[altı çizili](underline: true), ^[büyük](size: 24).`

const prop = (description: string) => ({ type: 'string', description })
const tool = (name: string, description: string, properties: Json, required: string[] = [], readOnly = false) => ({
  name, description, inputSchema: { type: 'object', properties, required },
  annotations: { readOnlyHint: readOnly, destructiveHint: false },
})

const TOOLS = [
  tool('list_notebooks', 'Tüm defterleri (gruplar) listeler.', {}, [], true),
  tool('list_pages', 'Sayfaları listeler; isteğe bağlı olarak bir deftere göre filtreler.', { notebook: prop('Defter adı veya id\'si') }, [], true),
  tool('read_page', 'Bir sayfanın tüm içeriğini Markdown olarak (blok id\'leriyle) döndürür.', { page: prop('Sayfa id\'si veya tam başlığı') }, ['page'], true),
  tool('list_open_tasks', 'Tamamlanmamış yapılacak maddelerini task_id\'leriyle, atanan kişi ve son tarihle listeler.', {
    notebook: prop('Defter adı veya id\'si (opsiyonel)'), page: prop('Sayfa id\'si veya başlığı (opsiyonel)'),
    assignee: prop('Yalnızca bu kişiye atananlar: "me" (kullanıcı) ya da kişi adı (opsiyonel)'),
  }, [], true),
  tool('list_people', 'Paylaşılan defterlerdeki ekip üyelerini, rollerini ve açık görev sayılarını listeler.', { notebook: prop('Defter adı veya id\'si (opsiyonel)') }, [], true),
  tool('assign_task', 'Görevi bir ekip üyesine atar (kişiye bildirim gider). Boş person atamayı kaldırır.', {
    task_id: prop('Görev id\'si'), person: prop('"me" ya da list_people\'daki kişi adı; boş = atamayı kaldır'),
  }, ['task_id']),
  tool('set_due_date', 'Göreve son tarih / hatırlatma koyar (atanan kişiye o saatte bildirim gider). Boş due kaldırır.', {
    task_id: prop('Görev id\'si'), due: prop('ISO 8601 tarih, ör. 2026-10-12T17:00:00+03:00; boş = kaldır'),
  }, ['task_id']),
  tool('list_comments', 'Bir görevin (ya da bloğun) yorumlarını yazar ve zamanıyla listeler.', { task_id: prop('Görev / blok id\'si') }, ['task_id'], true),
  tool('add_comment', 'Göreve yapay zeka adına yorum yazar (ilerleme, soru, sonuç). "@İsim" ile ekip üyesinden bahsedilirse ona bildirim gider.', {
    task_id: prop('Görev / blok id\'si'), text: prop('Yorum metni (Markdown)'),
  }, ['task_id', 'text']),
  tool('complete_task', 'Bir yapılacak maddesini yapay zeka tarafından tamamlandı olarak işaretler. Yalnızca işi doğruladıktan sonra çağır.', {
    task_id: prop('Görev id\'si'), note: prop('Ne yapıldığına dair kısa açıklama; kullanıcıya gösterilir'),
  }, ['task_id']),
  tool('reopen_task', 'Tamamlanmış bir maddeyi yeniden açar.', { task_id: prop('Görev id\'si') }, ['task_id']),
  tool('add_task', 'Bir sayfaya yeni yapılacak maddesi ekler.', {
    page: prop('Sayfa id\'si veya başlığı'), text: prop('Madde metni'), after_task_id: prop('Bu maddenin arkasına ekle (opsiyonel)'),
  }, ['page', 'text']),
  tool('create_page', 'Yeni sayfa oluşturur. İçerik Markdown olabilir (- [ ] görev, # başlık, - madde, > alıntı, ``` kod).', {
    notebook: prop('Defter adı (yoksa oluşturulur)'), title: prop('Sayfa başlığı'), content: prop('Markdown içerik'),
    layout: { type: 'string', enum: ['document', 'canvas'] },
  }, ['notebook', 'title']),
  tool('append_to_page', 'Var olan bir sayfanın sonuna Markdown içerik ekler.', {
    page: prop('Sayfa id\'si veya başlığı'), content: prop('Markdown içerik'),
  }, ['page', 'content']),
  tool('search', 'Tüm notlarda metin araması yapar.', { query: prop('Aranacak metin') }, ['query'], true),
]
