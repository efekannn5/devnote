// Not listesi (Mac'teki PageListView): filtre, arama, sabitlenenler üstte, "Yeni Not" (Belge / Tuval).

import { useEffect } from 'react'
import { flushSync } from 'react-dom'
import { FilePlus2, FileText, Folder, LayoutGrid, Pin, Sparkles, SquarePen, Trash2, Users } from 'lucide-react'
import { get, update, type Rec } from '../model/store'
import { bk, canEdit, createNotebook, createPage, deleteRec, isShared, isSharedWithMe, me, movePage, nb, pg, sortedBlocks, type PageLayout } from '../model/ops'
import { plainText } from '../lib/markdown'
import { ProgressRing, relative, showMenu, useVersion } from './common'
import { SMART_TITLES, focusBlock, openPage, useUI } from './state'
import { allPages, notebooksSorted, tasksOf } from './Sidebar'

function filtered(): Rec[] {
  const { sidebar, search } = useUI.getState()
  const myID = me().id
  let base = allPages()
  switch (sidebar.type) {
    case 'pinned': base = base.filter(pg.pinned); break
    case 'openTasks': base = base.filter((p) => tasksOf(p).some((b) => !bk.done(b))); break
    case 'assignedToMe': base = base.filter((p) => tasksOf(p).some((b) => !bk.done(b) && b.f.assigneeID_ === myID)); break
    case 'aiCompleted': base = base.filter((p) => tasksOf(p).some((b) => b.f.doneBy_ === 'ai')); break
    case 'notebook': base = base.filter((p) => p.parent === sidebar.uuid); break
  }
  const q = search.trim().toLocaleLowerCase('tr')
  if (q) base = base.filter((p) => pg.title(p).toLocaleLowerCase('tr').includes(q) || sortedBlocks(p).some((b) => bk.text(b).toLocaleLowerCase('tr').includes(q)))
  base.sort((a, b) => pg.updatedAt(b) - pg.updatedAt(a))
  return [...base.filter(pg.pinned), ...base.filter((p) => !pg.pinned(p))]
}

export function newPage(layout: PageLayout) {
  const { sidebar } = useUI.getState()
  let notebook = sidebar.type === 'notebook' ? get('Notebook', sidebar.uuid) : notebooksSorted().find((n) => !isSharedWithMe(n))
  if (notebook && !canEdit(notebook)) notebook = notebooksSorted().find((n) => !isSharedWithMe(n))
  if (!notebook) notebook = createNotebook('Notlar', 'book.closed.fill', '#0A84FF', notebooksSorted().length)
  const page = createPage('', notebook, layout)
  // Hemen çiz ve başlığa odaklan: yazılan ilk harfler kaybolmasın
  flushSync(() => openPage(page.uuid))
  ;(document.querySelector('.page-title') as HTMLTextAreaElement | null)?.focus()
}

export function newPageMenu(anchor: HTMLElement) {
  showMenu(anchor, [
    { section: 'Yeni not nasıl olsun?' },
    { label: 'Belge — Notion gibi bloklar', icon: FileText, shortcut: 'Ctrl+N', onClick: () => newPage('document') },
    { label: 'Tuval — serbest kutular ve çizim', icon: LayoutGrid, shortcut: 'Ctrl+Shift+N', onClick: () => newPage('canvas') },
  ])
}

export function PageList() {
  useVersion()
  const sidebar = useUI((s) => s.sidebar)
  const search = useUI((s) => s.search)
  const selected = useUI((s) => s.page)
  const pages = filtered()
  const title = sidebar.type === 'notebook' ? nb.name(get('Notebook', sidebar.uuid)) : SMART_TITLES[sidebar.type]

  // Kısayollar: Ctrl+N belge, Ctrl+Shift+N tuval
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'n') { e.preventDefault(); newPage(e.shiftKey ? 'canvas' : 'document') }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  const menu = (page: Rec, x: number, y: number) => {
    const movable = notebooksSorted().filter((n) => n.zoneOwner === page.zoneOwner && n.uuid !== page.parent)
    showMenu({ x, y }, [
      { label: pg.pinned(page) ? 'Sabitlemeyi Kaldır' : 'Sabitle', icon: Pin, onClick: () => update(page, { isPinned: !pg.pinned(page) }) },
      ...(movable.length && canEdit(page) ? [{ label: 'Deftere Taşı', icon: Folder, submenu: movable.map((n) => ({ label: nb.name(n), onClick: () => movePage(page, n) })) }] : []),
      'sep',
      { label: 'Sil', icon: Trash2, danger: true, onClick: () => { if (useUI.getState().page === page.uuid) openPage(null); deleteRec(page) } },
    ])
  }

  return (
    <>
      <div className="toolbar" data-tauri-drag-region>
        <span className="title" data-tauri-drag-region>{title}</span>
        <div className="glass-group">
          <button className="tb-btn" title="Yeni Not" aria-label="Yeni Not" data-testid="new-note" onClick={(e) => newPageMenu(e.currentTarget)}>
            <SquarePen size={16} strokeWidth={1.8} />
          </button>
        </div>
      </div>
      <div
        className="page-list"
        tabIndex={0}
        onKeyDown={(e) => {
          if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return
          e.preventDefault()
          const i = pages.findIndex((p) => p.uuid === selected)
          const next = pages[Math.min(Math.max(i + (e.key === 'ArrowDown' ? 1 : -1), 0), pages.length - 1)]
          if (next) openPage(next.uuid)
        }}
      >
        {pages.map((p) => (
          <PageRow key={p.uuid} page={p} selected={p.uuid === selected} onContext={(x, y) => menu(p, x, y)} />
        ))}
        {pages.length === 0 && (
          <div className="empty" style={{ height: '70%' }}>
            {search ? <FilePlus2 size={30} strokeWidth={1.4} /> : <SquarePen size={30} strokeWidth={1.4} />}
            <div className="big">{search ? 'Sonuç yok' : 'Henüz not yok'}</div>
          </div>
        )}
      </div>
    </>
  )
}

function snippet(page: Rec) {
  const text = sortedBlocks(page).map((b) => plainText(bk.text(b))).find((t) => t.trim())
  return text ?? ''
}

function PageRow({ page, selected, onContext }: { page: Rec; selected: boolean; onContext: (x: number, y: number) => void }) {
  const notebook = get('Notebook', page.parent)
  const tasks = tasksOf(page)
  const done = tasks.filter(bk.done).length
  const ai = tasks.some((b) => b.f.doneBy_ === 'ai')
  const text = snippet(page)
  return (
    <div
      className={`page-row${selected ? ' selected' : ''}`}
      onClick={() => openPage(page.uuid)}
      onDoubleClick={() => { const first = sortedBlocks(page)[0]; if (first) focusBlock(first.uuid, 'end') }}
      onContextMenu={(e) => { e.preventDefault(); openPage(page.uuid); onContext(e.clientX, e.clientY) }}
    >
      <div className="head">
        {pg.pinned(page) && <Pin size={10} fill="#FF9500" color="#FF9500" style={selected ? { color: 'white', fill: 'white' } : undefined} />}
        <span className="title" style={!pg.title(page) ? { color: selected ? 'rgba(255,255,255,.8)' : 'var(--text-2)' } : undefined}>{pg.title(page) || 'Başlıksız'}</span>
        {pg.layout(page) === 'canvas' && <LayoutGrid size={12} style={{ opacity: 0.6 }} />}
        {tasks.length > 0 && <ProgressRing progress={done / tasks.length} tint={selected ? '#fff' : nb.color(notebook)} size={14} />}
      </div>
      <div className="sub">{text || 'Ek metin yok'}</div>
      <div className="meta">
        {notebook && (
          <>
            <span className="dot" style={{ background: nb.color(notebook) }} />
            <span>{nb.name(notebook)}</span>
            {isShared(notebook) && <Users size={10} fill="currentColor" />}
          </>
        )}
        <span>{relative(pg.updatedAt(page) || Number(page.f.createdAt_ ?? Date.now()))}</span>
        {ai && <Sparkles size={10} color={selected ? '#fff' : '#BF5AF2'} />}
      </div>
    </div>
  )
}
