// Mac'teki sheet'ler: defter düzenleyici, yorumlar, ekip, hata kayıtları, ayarlar, görsel görüntüleyici.

import { useEffect, useMemo, useRef, useState } from 'react'
import {
  ArrowUp, Bell, Cloud, CloudOff, CheckCircle2, ChevronDown, ChevronRight, Circle, Copy, Eye, FilePlus2, FileText, Hourglass, LogOut, MessageSquare,
  Pencil, RefreshCw, Trash2, User, UserPlus, Users, BadgeCheck,
} from 'lucide-react'
import { get, remove, update, useStore, type AssetRef, type Rec } from '../model/store'
import {
  addComment, assign, bk, canEdit, commentsOf, createNotebook, isShared, isSharedWithMe, me, myDisplayName, nb, participants, pg, sortedBlocks,
} from '../model/ops'
import { parseInline, plainText, type Run } from '../lib/markdown'
import { native } from '../lib/native'
import { clearRecent, useErrors } from '../lib/errors'
import { setSettings, useSettings } from '../lib/settings'
import { NOTEBOOK_ICONS, SFIcon } from './icons'
import { Avatar, Sheet, relative, showMenu, useVersion } from './common'
import { openSheet, openTask, select, useUI, type Sheet as SheetType } from './state'
import { notebooksSorted, tasksOf } from './Sidebar'
import { startMcp, teamMembers } from '../mcp/tools'
import { useSync, engine } from '../sync/engine'
import { signIn, signOut, CALLBACK_URL } from '../sync/auth'
import { ck } from '../sync/cloudkit'
import { imageURL } from './editor/images'

export const PALETTE = ['#0A84FF', '#5E5CE6', '#BF5AF2', '#FF375F', '#FF9F0A', '#FFD60A', '#30D158', '#64D2FF', '#8E8E93']

export function SheetHost() {
  useVersion()
  const sheet = useUI((s) => s.sheet)
  if (!sheet) return null
  const close = () => openSheet(null)
  return <SheetFor sheet={sheet} close={close} />
}

function SheetFor({ sheet, close }: { sheet: SheetType; close: () => void }) {
  switch (sheet.type) {
    case 'notebook': return <NotebookEditor uuid={sheet.uuid} close={close} />
    case 'comments': return <CommentsSheet blockID={sheet.block} close={close} />
    case 'team': return <TeamSheet notebookID={sheet.notebook} close={close} />
    case 'errors': return <ErrorLog close={close} />
    case 'settings': return <SettingsSheet close={close} />
    case 'image': return <ImageViewer blockID={sheet.block} close={close} />
    default: return null
  }
}

// MARK: - Defter

function NotebookEditor({ uuid, close }: { uuid?: string; close: () => void }) {
  const notebook = uuid ? get('Notebook', uuid) : undefined
  const [name, setName] = useState(notebook ? nb.name(notebook) : '')
  const [icon, setIcon] = useState(notebook ? nb.icon(notebook) : NOTEBOOK_ICONS[0])
  const [color, setColor] = useState(notebook ? nb.color(notebook).toUpperCase() : PALETTE[0])
  const save = () => {
    if (!name.trim()) return
    if (notebook) update(notebook, { name_: name, icon_: icon, colorHex_: color })
    else {
      const created = createNotebook(name, icon, color, notebooksSorted().length)
      select({ type: 'notebook', uuid: created.uuid })
    }
    close()
  }
  return (
    <Sheet onClose={close} width={400} actions={<>
      <button className="btn" onClick={close}>Vazgeç</button>
      <button className="btn primary" disabled={!name.trim()} onClick={save}>{notebook ? 'Kaydet' : 'Oluştur'}</button>
    </>}>
      <div className="sheet-body" style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>
        <div style={{ display: 'flex', gap: 14, alignItems: 'center' }}>
          <div style={{ width: 54, height: 54, borderRadius: 14, display: 'flex', alignItems: 'center', justifyContent: 'center', background: `linear-gradient(180deg, color-mix(in srgb, ${color} 80%, white), ${color})`, flex: 'none' }}>
            <SFIcon name={icon} size={26} color="white" fill />
          </div>
          <input
            className="plain-title" autoFocus placeholder="Defter adı" value={name}
            onChange={(e) => setName(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') save() }}
          />
        </div>
        <div style={{ display: 'flex', gap: 10 }}>
          {PALETTE.map((hex) => (
            <button key={hex} className="color-dot" aria-label={hex} onClick={() => setColor(hex)}
              style={{ background: hex, boxShadow: hex === color ? `0 0 0 2px var(--bg), 0 0 0 4px color-mix(in srgb, var(--text) 60%, transparent)` : undefined }} />
          ))}
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 34px)', gap: 8 }}>
          {NOTEBOOK_ICONS.map((sym) => (
            <button key={sym} className="icon-cell" onClick={() => setIcon(sym)}
              style={{ background: sym === icon ? `color-mix(in srgb, ${color} 20%, transparent)` : 'transparent', color: sym === icon ? color : 'var(--text-2)' }}>
              <SFIcon name={sym} size={17} color="currentColor" fill={sym === icon} />
            </button>
          ))}
        </div>
      </div>
    </Sheet>
  )
}

// MARK: - Yorumlar

function RichInline({ text, highlight, accent }: { text: string; highlight?: string[]; accent?: string }) {
  const runs = parseInline(text)
  return <>{runs.map((r, i) => <RunView key={i} run={r} highlight={highlight} accent={accent} />)}</>
}

function RunView({ run, highlight, accent }: { run: Run; highlight?: string[]; accent?: string }) {
  const s = run.style
  let node: React.ReactNode = run.text
  if (highlight?.length) {
    const pattern = new RegExp(`(${highlight.map((h) => '@' + h.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')})`, 'gi')
    node = run.text.split(pattern).map((part, i) => (i % 2 ? <b key={i} style={{ color: accent }}>{part}</b> : part))
  }
  if (s.code) node = <code>{node}</code>
  if (s.link) node = <a href={s.link} onClick={(e) => { e.preventDefault(); void native.openURL(s.link!) }}>{node}</a>
  const style: React.CSSProperties = {
    fontWeight: s.bold ? 700 : undefined, fontStyle: s.italic ? 'italic' : undefined,
    textDecoration: [s.strike && 'line-through', s.underline && 'underline'].filter(Boolean).join(' ') || undefined,
    color: s.color, background: s.highlight ? `color-mix(in srgb, ${s.highlight} 38%, transparent)` : undefined,
    fontSize: s.size ? (s.size <= 4 ? `${s.size}em` : s.size) : undefined,
  }
  return <span style={style}>{node}</span>
}

function CommentsSheet({ blockID, close }: { blockID: string; close: () => void }) {
  const block = get('Block', blockID)
  const page = block ? get('Page', block.parent) : undefined
  const notebook = page ? get('Notebook', page.parent) : undefined
  const accent = nb.color(notebook)
  const people = participants(notebook)
  const editable = canEdit(block)
  const [draft, setDraft] = useState('')
  const listRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLTextAreaElement>(null)
  const comments = block ? commentsOf(block) : []
  useEffect(() => { listRef.current?.scrollTo({ top: listRef.current.scrollHeight, behavior: 'smooth' }) }, [comments.length])
  if (!block) return null

  const words = draft.split(' ')
  const lastWord = words[words.length - 1]
  const query = lastWord.startsWith('@') ? lastWord.slice(1).toLocaleLowerCase('tr') : null
  const suggestions = query === null ? [] : people.filter((p) => !p.isMe && (!query || p.name.toLocaleLowerCase('tr').includes(query)))

  const send = () => {
    const text = draft.trim()
    if (!text) return
    addComment(block, text, people)
    setDraft('')
  }
  const mention = (name: string) => {
    const w = [...words]; w.pop(); w.push(`@${name} `)
    setDraft(w.join(' '))
    inputRef.current?.focus()
  }

  return (
    <Sheet onClose={close} width={460} title={<><span>Yorumlar</span><button className="btn" onClick={close}>Bitti</button></>}>
      <div ref={listRef} className="sheet-body" style={{ minHeight: 260, maxHeight: 460, paddingTop: 8 }}>
        <div style={{ paddingBottom: 12, borderBottom: '1px solid var(--separator)', marginBottom: 6 }}>
          <div style={{ display: 'flex', gap: 8, alignItems: 'baseline', fontWeight: 600, fontSize: 14 }}>
            {bk.kind(block) === 'checklist' && (bk.done(block) ? <CheckCircle2 size={14} color={accent} /> : <Circle size={14} color="var(--text-2)" />)}
            <span style={{ textDecoration: bk.done(block) ? 'line-through' : undefined }}><RichInline text={bk.text(block) || 'Başlıksız'} /></span>
          </div>
          <div style={{ display: 'flex', gap: 10, fontSize: 11, color: 'var(--text-2)', marginTop: 6 }}>
            {!!block.f.assigneeName_ && <span className="nb"><User size={11} fill="currentColor" /> {block.f.assigneeID_ === me().id ? 'Sana atandı' : String(block.f.assigneeName_)}</span>}
            {!!block.f.dueDate_ && <span className="nb" style={{ color: Number(block.f.dueDate_) < Date.now() && !bk.done(block) ? '#FF3B30' : '#FF9500' }}><Bell size={11} fill="currentColor" /> {relative(Number(block.f.dueDate_))}</span>}
            {page && <span className="nb"><FileText size={11} /> {pg.title(page) || 'Başlıksız'}</span>}
          </div>
        </div>
        {comments.length === 0 && <p style={{ color: 'var(--text-2)' }}>Henüz yorum yok. Soru sor, durum bildir ya da @ ile birinden bahset.</p>}
        {comments.map((c) => {
          const mine = c.f.authorID_ === me().id
          const author = String(c.f.authorName_ ?? '')
          return (
            <div key={c.uuid} className="comment" onContextMenu={(e) => {
              if (!mine) return
              e.preventDefault()
              showMenu({ x: e.clientX, y: e.clientY }, [{ label: 'Sil', icon: Trash2, danger: true, onClick: () => remove(c) }])
            }}>
              <Avatar name={author} tint={mine ? accent : '#8E8E93'} />
              <div style={{ minWidth: 0 }}>
                <div style={{ display: 'flex', gap: 6, alignItems: 'baseline' }}>
                  <b style={{ fontSize: 12 }}>{mine && !author.startsWith('Yapay zeka') ? 'Sen' : author}</b>
                  <span style={{ fontSize: 11, color: 'var(--text-2)' }}>{relative(Number(c.f.createdAt_))}</span>
                </div>
                <div style={{ userSelect: 'text', whiteSpace: 'pre-wrap' }}><RichInline text={String(c.f.text_ ?? '')} highlight={people.map((p) => p.name)} accent={accent} /></div>
              </div>
            </div>
          )
        })}
      </div>
      {editable && (
        <div className="comment-input">
          {suggestions.length > 0 && (
            <div style={{ display: 'flex', gap: 6, overflowX: 'auto', paddingBottom: 8 }}>
              {suggestions.map((p) => (
                <button key={p.id} className="mention-chip" onClick={() => mention(p.name)}>
                  <Avatar name={p.name} tint={accent} size={20} /> {p.name}
                </button>
              ))}
            </div>
          )}
          <div style={{ display: 'flex', gap: 10, alignItems: 'flex-end' }}>
            <textarea
              ref={inputRef} className="bubble-input" rows={1} autoFocus value={draft}
              placeholder={people.length > 1 ? 'Yorum yaz… (@ ile birinden bahset)' : 'Yorum yaz…'}
              onChange={(e) => { setDraft(e.target.value); e.target.style.height = '0'; e.target.style.height = `${Math.min(e.target.scrollHeight, 110)}px` }}
              onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send() } }}
            />
            <button className="send-btn" style={{ background: accent }} disabled={!draft.trim()} onClick={send} aria-label="Gönder"><ArrowUp size={17} strokeWidth={2.6} /></button>
          </div>
        </div>
      )}
    </Sheet>
  )
}

// MARK: - Ekip

interface Activity { id: string; kind: 'page' | 'assigned' | 'done' | 'comment'; date: number; actor: string; text: string; detail: string; taskID?: string }

function activity(notebook: Rec, days = 14): Activity[] {
  const since = Date.now() - days * 86_400_000
  const myID = me().id
  const myName = myDisplayName(notebook)
  const shared = isShared(notebook)
  const isMe = (name: unknown, id?: unknown) => (id !== undefined && id !== null ? id === myID : !shared || name == null || name === myName)
  const phrase = (meFlag: boolean, name: unknown, mine: string, theirs: string): [string, string] => (meFlag ? ['Sen', mine] : [String(name ?? 'Biri'), theirs])
  const short = (t: string) => { const p = plainText(t); return p ? p.slice(0, 80) : 'Başlıksız' }
  const events: Activity[] = []
  const pages = Object.values(useStore.getState().recs).filter((r) => r.entity === 'Page' && r.parent === notebook.uuid)
  for (const page of pages) {
    const created = Number(page.f.createdAt_ ?? 0)
    if (created > since) {
      const [actor, text] = phrase(isMe(page.f.authorName_), page.f.authorName_, 'sayfa oluşturdun', 'sayfa oluşturdu')
      events.push({ id: `page-${page.uuid}`, kind: 'page', date: created, actor, text, detail: short(pg.title(page)) })
    }
    for (const b of sortedBlocks(page)) {
      const comments = commentsOf(b)
      if (bk.kind(b) !== 'checklist' && !comments.length) continue
      const assignedAt = Number(b.f.assignedAt_ ?? 0)
      if (assignedAt > since && b.f.assigneeName_) {
        const to = b.f.assigneeID_ === b.f.assignedByID_ ? 'kendine' : b.f.assigneeID_ === myID ? 'sana' : `${b.f.assigneeName_} kişisine`
        const [actor, text] = phrase(isMe(b.f.assignedByName_, b.f.assignedByID_), b.f.assignedByName_, `${to} görev atadın`, `${to} görev atadı`)
        events.push({ id: `assign-${b.uuid}`, kind: 'assigned', date: assignedAt, actor, text, detail: short(bk.text(b)), taskID: b.uuid })
      }
      const doneAt = Number(b.f.doneAt_ ?? 0)
      if (bk.done(b) && doneAt > since) {
        const [actor, text] = phrase(isMe(b.f.doneByName_, b.f.doneByID_), b.f.doneByName_, 'görevi tamamladın', 'görevi tamamladı')
        events.push({ id: `done-${b.uuid}`, kind: 'done', date: doneAt, actor, text: b.f.doneBy_ === 'ai' ? 'görevi yapay zeka ile tamamladı' : text, detail: short(bk.text(b)), taskID: b.uuid })
      }
      for (const c of comments) {
        const at = Number(c.f.createdAt_ ?? 0)
        if (at <= since) continue
        const quote = `„${short(String(c.f.text_ ?? ''))}“`
        const author = String(c.f.authorName_ ?? '')
        const [actor, text] = phrase(c.f.authorID_ === myID && !author.startsWith('Yapay zeka'), author, `yorum yaptın: ${quote}`, `yorum yaptı: ${quote}`)
        events.push({ id: `comment-${c.uuid}`, kind: 'comment', date: at, actor, text, detail: short(bk.text(b)), taskID: b.uuid })
      }
    }
  }
  return events.sort((a, b) => b.date - a.date)
}

const ACTIVITY_ICONS = { page: FilePlus2, assigned: UserPlus, done: CheckCircle2, comment: MessageSquare }

function TeamSheet({ notebookID, close }: { notebookID: string; close: () => void }) {
  const notebook = get('Notebook', notebookID)
  const [showAll, setShowAll] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const [expanded, setExpanded] = useState<string | null>(null)
  const events = useMemo(() => (notebook ? activity(notebook) : []), [notebook])
  if (!notebook) return null
  const accent = nb.color(notebook)
  const members = teamMembers(notebook)
  const open = Object.values(useStore.getState().recs).filter((r) => r.entity === 'Page' && r.parent === notebook.uuid).flatMap(tasksOf).filter((b) => !bk.done(b))
  const unassigned = open.filter((b) => !b.f.assigneeID_)
  const shared = isShared(notebook)

  return (
    <Sheet onClose={close} width={460} title={<>
      <span>{nb.name(notebook)}</span>
      <span style={{ display: 'flex', gap: 6 }}>
        <button className="btn" aria-label="Yenile" onClick={async () => { setRefreshing(true); await engine.fetchNow(); setRefreshing(false) }}>
          <RefreshCw size={13} className={refreshing ? 'spin' : ''} />
        </button>
        <button className="btn" onClick={close}>Bitti</button>
      </span>
    </>}>
      <div className="sheet-body" style={{ display: 'flex', flexDirection: 'column', gap: 18, minHeight: 360 }}>
        {!shared && (
          <div className="info-box">
            <div style={{ fontWeight: 600, display: 'flex', gap: 6, alignItems: 'center' }}><Users size={14} /> Bu defter henüz paylaşılmadı</div>
            <p>Ekip arkadaşlarını iCloud ile davet et. Katıldıktan sonra notları birlikte düzenleyebilir, birbirinize görev atayabilirsiniz.</p>
            <p style={{ fontSize: 11 }}>Davet bağlantısı Apple'ın paylaşım ekranıyla oluşturulur: defteri Mac ya da iPhone'da paylaş — katılımcılar burada da anında görünür.</p>
          </div>
        )}
        <div>
          <div className="group-title">{members.length} kişi</div>
          <div className="group">
            {members.map((m) => {
              const tasks = open.filter((b) => b.f.assigneeID_ === m.person.id)
              const isOpen = expanded === m.person.id
              return (
                <div key={m.person.id}>
                  <div className="member-row" onClick={() => setExpanded(isOpen ? null : m.person.id)}>
                    {isOpen ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
                    <Avatar name={m.person.name} tint={m.person.isMe ? accent : '#8E8E93'} />
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                        <span style={{ fontWeight: 500 }}>{m.person.isMe ? 'Sen' : m.person.name}</span>
                        {m.isOwner && <span className="pill" style={{ background: `color-mix(in srgb, ${accent} 15%, transparent)`, color: accent }}>Sahip</span>}
                      </div>
                      <div style={{ display: 'flex', gap: 8, fontSize: 11, color: 'var(--text-2)' }}>
                        <span className="nb">{m.canEdit ? <><Pencil size={10} /> Düzenleyebilir</> : <><Eye size={10} /> Görüntüleyebilir</>}</span>
                        {!m.accepted && <span className="nb" style={{ color: '#FF9500' }}><Hourglass size={10} /> Davet bekliyor</span>}
                      </div>
                    </div>
                    {tasks.length > 0 && <span className="pill" style={{ background: 'var(--fill)' }}>{tasks.length}</span>}
                  </div>
                  {isOpen && (
                    <div style={{ padding: '2px 0 8px 54px', display: 'flex', flexDirection: 'column', gap: 6 }}>
                      {tasks.length === 0 ? <span style={{ color: 'var(--text-2)' }}>Açık görevi yok</span> : tasks.map((t) => (
                        <div key={t.uuid} style={{ display: 'flex', gap: 8, cursor: 'default' }} onClick={() => openTask(t.uuid)}>
                          <Circle size={13} color="var(--text-2)" style={{ marginTop: 2 }} />
                          <div>
                            <div>{plainText(bk.text(t))}</div>
                            {!!t.f.dueDate_ && <div style={{ fontSize: 11, color: Number(t.f.dueDate_) < Date.now() ? '#FF3B30' : '#FF9500' }}>{relative(Number(t.f.dueDate_))}</div>}
                          </div>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        </div>
        {events.length > 0 && (
          <div>
            <div className="group-title">Son etkinlikler</div>
            <div className="group">
              {events.slice(0, showAll ? 60 : 8).map((ev) => {
                const Icon = ACTIVITY_ICONS[ev.kind]
                return (
                  <div key={ev.id} className="activity-row" onClick={() => { if (ev.taskID) openTask(ev.taskID) }}>
                    <Icon size={15} color={ev.kind === 'done' ? '#30D158' : accent} fill={ev.kind === 'done' || ev.kind === 'comment' ? 'currentColor' : 'none'} fillOpacity={0.2} />
                    <div style={{ minWidth: 0 }}>
                      <div className="clamp2"><b>{ev.actor}</b> {ev.text}</div>
                      <div style={{ fontSize: 11, color: 'var(--text-2)', display: 'flex', gap: 6 }}>
                        <span className="ellipsis">{ev.detail}</span><span>·</span><span style={{ flex: 'none' }}>{relative(ev.date)}</span>
                      </div>
                    </div>
                  </div>
                )
              })}
              {events.length > 8 && !showAll && (
                <button className="link-btn" style={{ padding: '8px 10px', color: 'var(--accent)' }} onClick={() => setShowAll(true)}>
                  Tümünü göster ({Math.min(events.length, 60)})
                </button>
              )}
            </div>
          </div>
        )}
        {unassigned.length > 0 && shared && (
          <div>
            <div className="group-title">Atanmamış görevler</div>
            <div className="group">
              {unassigned.map((t) => (
                <div key={t.uuid} className="activity-row" style={{ alignItems: 'center' }}>
                  <span style={{ flex: 1 }} className="clamp2">{plainText(bk.text(t))}</span>
                  <button className="link-btn" style={{ color: 'var(--accent)' }} onClick={(e) => showMenu(e.currentTarget, members.filter((m) => m.accepted && m.person.id).map((m) => ({
                    label: m.person.isMe ? 'Bana ata' : m.person.name, onClick: () => assign(t, m.person),
                  })))}>
                    <UserPlus size={13} /> Ata
                  </button>
                </div>
              ))}
            </div>
          </div>
        )}
        {isSharedWithMe(notebook) && <p style={{ fontSize: 11, color: 'var(--text-3)' }}>Bu defter seninle paylaşıldı.</p>}
      </div>
    </Sheet>
  )
}

// MARK: - Hatalar

function ErrorLog({ close }: { close: () => void }) {
  const { recent, log } = useErrors()
  return (
    <Sheet onClose={close} width={540} title={<>
      <span>Hata Kayıtları</span>
      <span style={{ display: 'flex', gap: 6 }}>
        <button className="btn" disabled={!log.length} onClick={() => void navigator.clipboard.writeText(log.map((e) => `${new Date(e.date).toISOString()} [${e.area}] ${e.message}`).join('\n'))}>
          <Copy size={12} /> Kopyala
        </button>
        <button className="btn danger" disabled={!recent.length && !log.length} onClick={() => { clearRecent(); useErrors.setState({ log: [] }) }}>Temizle</button>
        <button className="btn" onClick={close}>Bitti</button>
      </span>
    </>}>
      <div className="sheet-body" style={{ minHeight: 320 }}>
        {!recent.length && !log.length && (
          <div className="empty" style={{ height: 260 }}>
            <BadgeCheck size={34} strokeWidth={1.4} />
            <div className="big">Kayıtlı hata yok</div>
            <div>Bir sorun olursa burada görünür.</div>
          </div>
        )}
        {recent.length > 0 && <div className="group-title">Bu oturum</div>}
        {recent.map((e) => (
          <div key={e.id} style={{ padding: '6px 0', borderBottom: '1px solid var(--separator)' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11 }}>
              <b style={{ color: '#FF9500' }}>{e.area}</b>
              <span style={{ color: 'var(--text-2)' }}>{new Date(e.date).toLocaleTimeString('tr-TR')}</span>
            </div>
            <div style={{ userSelect: 'text' }}>{e.message}</div>
          </div>
        ))}
        {log.length > 0 && (
          <>
            <div className="group-title" style={{ marginTop: 16 }}>Günlük</div>
            <pre className="log">{log.slice(0, 300).map((e) => `${new Date(e.date).toLocaleString('tr-TR')} [${e.area}] ${e.message}`).join('\n')}</pre>
          </>
        )}
      </div>
    </Sheet>
  )
}

// MARK: - Ayarlar

function SettingsSheet({ close }: { close: () => void }) {
  const { mcpEnabled, mcpPort } = useSettings()
  const sync = useSync()
  const [port, setPort] = useState(String(mcpPort))
  const [tab, setTab] = useState<'ai' | 'sync'>('ai')
  const [token, setToken] = useState('')
  const endpoint = `http://127.0.0.1:${mcpPort}/mcp`
  const snippets: [string, string][] = [
    ['Claude Code', `claude mcp add --transport http devnote ${endpoint}`],
    ['HTTP destekleyen istemciler (Cursor, VS Code…)', JSON.stringify({ mcpServers: { devnote: { type: 'http', url: endpoint } } }, null, 2)],
    ['Sadece stdio destekleyen istemciler (Claude Desktop)', JSON.stringify({ mcpServers: { devnote: { command: 'npx', args: ['-y', 'mcp-remote', endpoint] } } }, null, 2)],
  ]
  const applyPort = () => {
    const p = parseInt(port, 10)
    if (!(p > 1024 && p < 65536)) { setPort(String(mcpPort)); return }
    setSettings({ mcpPort: p })
    void startMcp()
  }
  return (
    <Sheet onClose={close} width={560} title={<>
      <div className="segmented">
        <button className={tab === 'ai' ? 'on' : ''} onClick={() => setTab('ai')}>Yapay Zeka</button>
        <button className={tab === 'sync' ? 'on' : ''} onClick={() => setTab('sync')}>Senkron</button>
      </div>
      <button className="btn" onClick={close}>Bitti</button>
    </>}>
      <div className="sheet-body" style={{ display: 'flex', flexDirection: 'column', gap: 16, minHeight: 420 }}>
        {tab === 'ai' ? (
          <>
            <div className="group" style={{ padding: 12, display: 'flex', flexDirection: 'column', gap: 10 }}>
              <label style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                Yerel MCP sunucusunu çalıştır
                <input type="checkbox" className="switch" checked={mcpEnabled} onChange={(e) => { setSettings({ mcpEnabled: e.target.checked }); void startMcp() }} />
              </label>
              <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                <input className="field" style={{ width: 90 }} value={port} onChange={(e) => setPort(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') applyPort() }} />
                <button className="btn" onClick={applyPort}>Uygula</button>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Adres</span><span style={{ color: 'var(--text-2)', userSelect: 'text' }}>{endpoint}</span></div>
              <div style={{ fontSize: 11, color: 'var(--text-2)' }}>Sunucu yalnızca 127.0.0.1 üzerinde dinler; ağdaki diğer cihazlar erişemez.</div>
            </div>
            <div className="group-title">Bağlan</div>
            {snippets.map(([title, text]) => (
              <div key={title}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
                  <span style={{ fontWeight: 500 }}>{title}</span>
                  <button className="link-btn" aria-label="Kopyala" onClick={() => void navigator.clipboard.writeText(text)}><Copy size={13} /></button>
                </div>
                <pre className="snippet">{text}</pre>
              </div>
            ))}
          </>
        ) : (
          <>
            <div className="group" style={{ padding: 12, display: 'flex', flexDirection: 'column', gap: 10 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, color: sync.signedIn ? '#0A84FF' : 'var(--text)' }}>
                <SFIconCloud on={sync.signedIn} /> {sync.signedIn ? 'iCloud senkronu açık' : 'iCloud oturumu kapalı'}
              </div>
              <div style={{ fontSize: 12, color: 'var(--text-2)' }}>{sync.text}</div>
              <div style={{ display: 'flex', gap: 8 }}>
                {sync.signedIn
                  ? <button className="btn danger" onClick={() => void signOut()}><LogOut size={12} /> Oturumu kapat</button>
                  : <button className="btn primary" onClick={() => void signIn()}>Apple ile giriş yap</button>}
                {sync.signedIn && <button className="btn" onClick={() => void engine.fetchNow()}><RefreshCw size={12} /> Şimdi eşitle</button>}
              </div>
            </div>
            {!ck.hasAPIToken || sync.needsAPIToken ? (
              <div className="group" style={{ padding: 12, display: 'flex', flexDirection: 'column', gap: 8 }}>
                <b>CloudKit API anahtarı</b>
                <div style={{ fontSize: 12, color: 'var(--text-2)' }}>CloudKit Console → API Access → API Tokens'ta oluşturulan anahtar (Sign In Callback: {CALLBACK_URL}).</div>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input className="field" placeholder="API anahtarı" value={token} onChange={(e) => setToken(e.target.value)} />
                  <button className="btn primary" disabled={!token.trim()} onClick={async () => { await ck.setAPIToken(token); useSync.setState({ needsAPIToken: false }); setToken('') }}>Kaydet</button>
                </div>
              </div>
            ) : null}
            <div style={{ fontSize: 11, color: 'var(--text-2)', lineHeight: 1.5 }}>
              Notlar Mac ve iPhone ile aynı iCloud kapsayıcısında (iCloud.com.efekan.devnote) tutulur. Değişiklikler anında gönderilir;
              uygulama açıkken birkaç saniyede bir yeniler çekilir. Giriş belirteci Windows Kimlik Bilgisi Yöneticisi'nde saklanır.
            </div>
          </>
        )}
      </div>
    </Sheet>
  )
}

function SFIconCloud({ on }: { on: boolean }) {
  return on ? <Cloud size={15} fill="currentColor" fillOpacity={0.2} /> : <CloudOff size={15} />
}

// MARK: - Görsel

function ImageViewer({ blockID, close }: { blockID: string; close: () => void }) {
  const block = get('Block', blockID)
  const [url, setURL] = useState<string | null>(null)
  const [scale, setScale] = useState(1)
  useEffect(() => { void imageURL(block?.f.imageData_ as AssetRef | undefined).then(setURL) }, [block])
  if (!block) return null
  return (
    <div className="viewer" onClick={close}>
      <div className="viewer-bar" onClick={(e) => e.stopPropagation()}>
        <button className="btn" onClick={close}>Kapat</button>
        <span>{bk.text(block)}</span>
        <span />
      </div>
      {url && (
        <img
          src={url}
          alt={bk.text(block)}
          style={{ transform: `scale(${scale})` }}
          onClick={(e) => { e.stopPropagation(); setScale(scale > 1 ? 1 : 2.5) }}
          onWheel={(e) => setScale((s) => Math.min(6, Math.max(1, s * (e.deltaY < 0 ? 1.1 : 0.9))))}
        />
      )}
    </div>
  )
}
