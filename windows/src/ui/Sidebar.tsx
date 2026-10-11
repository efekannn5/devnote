// Kenar çubuğu (Mac'teki SidebarView): akıllı listeler, defterlerim, benimle paylaşılanlar, durum çubuğu.

import { useState, type ReactNode } from 'react'
import { AlertTriangle, Cloud, CloudOff, FileSearch, FolderPlus, LogIn, Pencil, Search, Settings, Trash2, UserPlus, Users, X } from 'lucide-react'
import { useStore, update, type Rec } from '../model/store'
import { bk, deleteRec, isShared, isSharedWithMe, me, nb, sortedBlocks } from '../model/ops'
import { SFIcon } from './icons'
import { showMenu, useVersion } from './common'
import { SMART_TITLES, openSheet, sameItem, select, useUI, type SidebarItem } from './state'
import { useErrors } from '../lib/errors'
import { useSync } from '../sync/engine'
import { useMcp } from '../mcp/tools'
import { useSettings } from '../lib/settings'
import { signIn } from '../sync/auth'

export function notebooksSorted(): Rec[] {
  return Object.values(useStore.getState().recs)
    .filter((r) => r.entity === 'Notebook')
    .sort((a, b) => Number(a.f.sortIndex ?? 0) - Number(b.f.sortIndex ?? 0) || Number(a.f.createdAt_ ?? 0) - Number(b.f.createdAt_ ?? 0))
}
export const allPages = () => Object.values(useStore.getState().recs).filter((r) => r.entity === 'Page')
export const tasksOf = (page: Rec) => sortedBlocks(page).filter((b) => bk.kind(b) === 'checklist')

export function Sidebar() {
  useVersion()
  const sidebar = useUI((s) => s.sidebar)
  const search = useUI((s) => s.search)
  const notebooks = notebooksSorted()
  const pages = allPages()
  const myID = me().id
  const mine = notebooks.filter((n) => !isSharedWithMe(n))
  const shared = notebooks.filter(isSharedWithMe)
  const [dragNB, setDragNB] = useState<string | null>(null)
  const [dropNB, setDropNB] = useState<string | null>(null)

  const counts = {
    all: pages.length,
    pinned: pages.filter((p) => p.f.isPinned).length,
    openTasks: pages.reduce((s, p) => s + tasksOf(p).filter((b) => !bk.done(b)).length, 0),
    assignedToMe: pages.reduce((s, p) => s + tasksOf(p).filter((b) => !bk.done(b) && b.f.assigneeID_ === myID).length, 0),
    aiCompleted: pages.filter((p) => tasksOf(p).some((b) => b.f.doneBy_ === 'ai')).length,
  }

  const reorder = (dragged: string, before: string) => {
    const list = mine.filter((n) => n.uuid !== dragged)
    const moving = mine.find((n) => n.uuid === dragged)
    if (!moving) return
    const index = list.findIndex((n) => n.uuid === before)
    list.splice(index < 0 ? list.length : index, 0, moving)
    list.forEach((n, i) => { if (Number(n.f.sortIndex ?? -1) !== i) update(n, { sortIndex: i }) })
  }

  const notebookRow = (n: Rec, draggable: boolean) => {
    const item: SidebarItem = { type: 'notebook', uuid: n.uuid }
    const count = pages.filter((p) => p.parent === n.uuid).length
    return (
      <div
        key={n.uuid}
        className={`side-row${sameItem(sidebar, item) ? ' selected' : ''}${dropNB === n.uuid && dragNB !== n.uuid ? ' drop-target' : ''}`}
        onClick={() => select(item)}
        draggable={draggable}
        onDragStart={(e) => { setDragNB(n.uuid); e.dataTransfer.setData('text/x-devnote-notebook', n.uuid); e.dataTransfer.effectAllowed = 'move' }}
        onDragEnd={() => { setDragNB(null); setDropNB(null) }}
        onDragOver={(e) => { if (dragNB && draggable) { e.preventDefault(); setDropNB(n.uuid) } }}
        onDragLeave={() => setDropNB((d) => (d === n.uuid ? null : d))}
        onDrop={(e) => { e.preventDefault(); if (dragNB) reorder(dragNB, n.uuid); setDragNB(null); setDropNB(null) }}
        onContextMenu={(e) => {
          e.preventDefault()
          showMenu({ x: e.clientX, y: e.clientY }, [
            { label: isShared(n) ? 'Paylaşımı Yönet…' : 'Paylaş…', icon: UserPlus, onClick: () => openSheet({ type: 'team', notebook: n.uuid }) },
            'sep',
            { label: 'Düzenle…', icon: Pencil, onClick: () => openSheet({ type: 'notebook', uuid: n.uuid }) },
            'sep',
            {
              label: isSharedWithMe(n) ? 'Paylaşımdan Ayrıl' : 'Sil', icon: Trash2, danger: true,
              onClick: () => {
                if (sameItem(useUI.getState().sidebar, item)) select({ type: 'all' })
                deleteRec(n)
              },
            },
          ])
        }}
      >
        <SFIcon name={nb.icon(n)} size={15} color={nb.color(n)} fill />
        <span className="name">{nb.name(n)}</span>
        {isShared(n) && <Users size={10} fill="currentColor" style={{ color: 'var(--text-2)' }} />}
        <span className="count">{count}</span>
      </div>
    )
  }

  return (
    <div className="sidebar-wrap" style={{ width: useSettings((s) => s.sidebarWidth) }}>
      <aside className="sidebar">
        <div className="sidebar-top" data-tauri-drag-region>
          <img src="/logo.png" alt="" width={18} height={18} style={{ borderRadius: 5 }} data-tauri-drag-region />
          <span className="app-title" data-tauri-drag-region>DevNote</span>
          <button className="tb-btn" title="Ayarlar" aria-label="Ayarlar" onClick={() => openSheet({ type: 'settings' })}><Settings size={15} strokeWidth={1.8} /></button>
          <button className="tb-btn" title="Yeni Defter" aria-label="Yeni Defter" onClick={() => openSheet({ type: 'notebook' })}><FolderPlus size={16} strokeWidth={1.8} /></button>
        </div>
        <div className="search sidebar-search">
          <Search size={13} />
          <input placeholder="Notlarda ara" value={search} onChange={(e) => useUI.setState({ search: e.target.value })} aria-label="Notlarda ara" />
          {search && <button className="clear" onClick={() => useUI.setState({ search: '' })} aria-label="Aramayı temizle"><X size={11} strokeWidth={3} /></button>}
        </div>
        <div className="sidebar-scroll">
          <div className="section-title">Akıllı Listeler</div>
          <Smart item={{ type: 'all' }} icon={<SFIcon name="tray.full.fill" size={15} color="#8E8E93" fill />} count={counts.all} />
          <Smart item={{ type: 'pinned' }} icon={<SFIcon name="pin.fill" size={15} color="#FF9500" fill />} count={counts.pinned} />
          <Smart item={{ type: 'openTasks' }} icon={<SFIcon name="checklist" size={15} color="#0A84FF" />} count={counts.openTasks} />
          <Smart item={{ type: 'assignedToMe' }} icon={<SFIcon name="person.crop.circle.badge.checkmark" size={15} color="#30D158" />} count={counts.assignedToMe} />
          <Smart item={{ type: 'aiCompleted' }} icon={<SFIcon name="sparkles" size={15} color="#BF5AF2" fill />} count={counts.aiCompleted} />

          <div className="section-title">Defterlerim</div>
          {mine.map((n) => notebookRow(n, true))}

          {shared.length > 0 && (
            <>
              <div className="section-title">Benimle Paylaşılanlar</div>
              {shared.map((n) => notebookRow(n, false))}
            </>
          )}
        </div>
        <StatusBar />
      </aside>
    </div>
  )
}

function Smart({ item, icon, count }: { item: SidebarItem; icon: ReactNode; count: number }) {
  const sidebar = useUI((s) => s.sidebar)
  return (
    <div className={`side-row${sameItem(sidebar, item) ? ' selected' : ''}`} onClick={() => select(item)}>
      {icon}
      <span className="name">{SMART_TITLES[item.type]}</span>
      <span className="count">{count}</span>
    </div>
  )
}

function StatusBar() {
  const mcp = useMcp()
  const port = useSettings((s) => s.mcpPort)
  const sync = useSync()
  const errors = useErrors((s) => s.recent)
  return (
    <div className="status-bar">
      <div className="status-line" style={{ alignItems: 'flex-start' }}>
        <span className="mcp-dot" style={{ background: mcp.running ? '#30D158' : '#FF3B30', boxShadow: mcp.running ? '0 0 4px #30D158' : 'none', marginTop: 4 }} />
        <div style={{ display: 'flex', flexDirection: 'column', gap: 1, minWidth: 0 }}>
          <span style={{ fontSize: 12, fontWeight: 500, color: 'var(--text)' }}>{mcp.running ? `MCP · localhost:${port}` : 'MCP kapalı'}</span>
          {mcp.lastActivity && <span className="t" style={{ fontSize: 11 }}>{mcp.lastActivity}</span>}
        </div>
      </div>
      <div className="status-line">
        {sync.signedIn ? <Cloud size={12} /> : <CloudOff size={12} />}
        <span className="t" title={sync.text}>{sync.text}</span>
        {!sync.signedIn && (
          <button className="link-btn" onClick={() => void signIn()} title="iCloud'a giriş yap"><LogIn size={12} /> Giriş</button>
        )}
        <button className="link-btn" onClick={() => openSheet({ type: 'errors' })} title="Hata kayıtları" aria-label="Hata kayıtları">
          {errors.length ? <span style={{ color: '#FF9500', display: 'inline-flex', gap: 3, alignItems: 'center', fontWeight: 600 }}><AlertTriangle size={12} fill="currentColor" stroke="var(--sidebar)" /> {errors.length}</span> : <FileSearch size={12} />}
        </button>
      </div>
    </div>
  )
}
