// Sayfa editörü (Mac'teki PageEditorView): başlık, araç çubuğu, biçim çubuğu; Belge ve Tuval modları.

import { useCallback, useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type DragEvent, type PointerEvent as RPointerEvent } from 'react'
import { FolderOpen, GripVertical, Lock, MoveHorizontal, Pencil, Pin, Plus, Users } from 'lucide-react'
import { get, remove, update, type Rec } from '../../model/store'
import {
  addBlock, bk, canEdit as canEditRec, estimatedCanvasHeight, isShared, moveBlock, myDisplayName, nb, participants, pg,
  sortedBlocks, touch, type BlockKind,
} from '../../model/ops'
import { SFIcon } from '../icons'
import { ProgressRing, dayMonthTime, showMenu, useVersion } from '../common'
import { focusBlock, openSheet, useUI } from '../state'
import { BlockRow } from './BlockRow'
import { BlockMenu, FormatToolbar, SlashMenu, insertMenu } from './Menus'
import { INSERTABLE, TEXT_KINDS, hasText, perform, requestPhoto, usePhotoRequest } from './blockOps'
import { addImages, pickImages } from './images'
import { useFormat } from './format'
import { WindowControls } from '../WindowControls'

const MARGIN = 48
const GUTTER = 44
const CARD_WIDTH = 420

export function PageEditor({ pageID }: { pageID: string }) {
  useVersion()
  const page = get('Page', pageID)
  const photo = usePhotoRequest()
  const lastPhoto = useRef(photo.n)
  // Sayfa kapanınca odak / menü durumu kalmasın
  useEffect(() => () => useUI.setState({ focus: null }), [pageID])

  // "/" menüsünden Görsel → dosya seçici
  useEffect(() => {
    if (photo.n === lastPhoto.current) return
    lastPhoto.current = photo.n
    const current = get('Page', pageID)
    if (!current) return
    void pickImages().then((files) => {
      const anchor = photo.anchor ? get('Block', photo.anchor) ?? null : focusedBlock(current)
      const replacing = photo.replacing ? get('Block', photo.replacing) ?? null : null
      if (files.length) void addImages(current, files, anchor, replacing)
    })
  }, [photo.n, photo.anchor, photo.replacing, pageID])

  if (!page) return null
  const notebook = get('Notebook', page.parent)
  const accent = nb.color(notebook)
  const editable = canEditRec(page)
  const layout = pg.layout(page)

  const onDrop = (e: DragEvent) => {
    const files = [...e.dataTransfer.files].filter((f) => f.type.startsWith('image/'))
    if (!files.length || !editable) return
    e.preventDefault()
    void addImages(page, files, sortedBlocks(page).at(-1) ?? null)
  }

  return (
    <div className="column detail-column" onDragOver={(e) => { if (e.dataTransfer.types.includes('Files')) e.preventDefault() }} onDrop={onDrop}>
      <div className="toolbar" data-tauri-drag-region>
        <div className="spacer" data-tauri-drag-region />
        <div className="glass-group">
          {notebook && (
            <button className="tb-btn" title="Ekip, davet ve görev atama" onClick={() => openSheet({ type: 'team', notebook: notebook.uuid })}>
              <Users size={16} strokeWidth={1.8} />
            </button>
          )}
          <button
            className="tb-btn" title="Ekle" disabled={!editable} aria-label="Ekle"
            onMouseDown={(e) => e.preventDefault()}
            onClick={(e) => showMenu(e.currentTarget, [
              ...insertMenu((k) => add(page, k), TEXT_KINDS),
              'sep',
              { label: 'Dosyadan Görsel…', icon: FolderOpen, onClick: () => requestPhoto(focusedBlock(page)?.uuid ?? null) },
            ])}
          >
            <Plus size={17} strokeWidth={1.8} />
          </button>
          <button className={`tb-btn${pg.pinned(page) ? ' on' : ''}`} title="Sabitle" aria-label="Sabitle" onClick={() => update(page, { isPinned: !pg.pinned(page) })}>
            <Pin size={15} strokeWidth={1.8} fill={pg.pinned(page) ? 'currentColor' : 'none'} />
          </button>
        </div>
        <WindowControls />
      </div>
      {editable && <FormatToolbar />}
      {layout === 'document'
        ? <DocumentView page={page} accent={accent} canEdit={editable} />
        : <CanvasView page={page} accent={accent} canEdit={editable} />}
    </div>
  )
}

function focusedBlock(page: Rec): Rec | null {
  const id = useUI.getState().focus
  const b = id ? get('Block', id) : undefined
  return b && b.parent === page.uuid ? b : null
}

/** Araç çubuğundaki "+": odaktaki satırın altına (tuvalde görünen alana) */
function add(page: Rec, kind: BlockKind) {
  const after = focusedBlock(page)
  if (kind === 'image') { requestPhoto(after?.uuid ?? null); return }
  const extra: Record<string, unknown> = {}
  if (pg.layout(page) === 'canvas') {
    const n = sortedBlocks(page).length
    Object.assign(extra, { x: 40 + (n % 6) * 24, y: 20 + (n % 6) * 24, isPlaced: true })
  }
  const block = addBlock(page, kind, '', after, extra)
  focusBlock(block.uuid, 'start')
}

// MARK: - Başlık

function Header({ page, maxWidth }: { page: Rec; maxWidth?: number }) {
  const notebook = get('Notebook', page.parent)
  const editable = canEditRec(page)
  const blocks = sortedBlocks(page)
  const tasks = blocks.filter((b) => bk.kind(b) === 'checklist')
  const done = tasks.filter(bk.done).length
  const accent = nb.color(notebook)
  const ref = useRef<HTMLTextAreaElement>(null)
  const [title, setTitle] = useState(pg.title(page))
  const editing = useRef(false)
  useEffect(() => { if (!editing.current) setTitle(pg.title(page)) }, [page])
  useLayoutEffect(() => {
    const el = ref.current
    if (el) { el.style.height = '0'; el.style.height = `${el.scrollHeight}px` }
  }, [title])
  const people = participants(notebook)
  const shared = notebook && isShared(notebook)
  const editor = page.f.lastEditorName_ as string | undefined

  return (
    <div style={{ maxWidth }}>
      <textarea
        ref={ref}
        className="page-title"
        rows={1}
        placeholder="Başlıksız"
        value={title}
        disabled={!editable}
        onFocus={() => { editing.current = true }}
        onBlur={() => { editing.current = false }}
        onChange={(e) => {
          const value = e.target.value.replace(/\n/g, ' ')
          setTitle(value)
          update(get('Page', page.uuid)!, { title_: value })
          touch(get('Page', page.uuid))
        }}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || (e.key === 'ArrowDown' && e.currentTarget.selectionStart === e.currentTarget.value.length)) {
            e.preventDefault()
            const first = sortedBlocks(page).find((b) => hasText(bk.kind(b)) && bk.kind(b) !== 'image')
            if (first) focusBlock(first.uuid, 'start')
            else if (pg.layout(page) === 'document') focusBlock(addBlock(page, 'text').uuid, 'start')
          }
        }}
      />
      <div className="page-meta">
        {notebook && (
          <span className="nb" style={{ color: accent }}>
            <SFIcon name={nb.icon(notebook)} size={12} color={accent} fill /> {nb.name(notebook)}
          </span>
        )}
        <span>{dayMonthTime(pg.updatedAt(page) || Date.now())}</span>
        {shared && editor && editor !== myDisplayName(notebook) && (
          <span className="nb" title="Son düzenleyen"><Pencil size={11} /> {editor}</span>
        )}
        {shared && (
          <button className="chip-btn" onClick={() => openSheet({ type: 'team', notebook: notebook.uuid })}>
            <Users size={12} fill="currentColor" /> {people.length > 1 ? `${people.length} kişi` : 'Paylaşıldı'}
          </button>
        )}
        {shared && !editable && <span className="nb"><Lock size={11} fill="currentColor" /> Salt okunur</span>}
        {tasks.length > 0 && (
          <span className="nb" style={{ gap: 5 }}>
            <ProgressRing progress={done / tasks.length} tint={accent} size={12} />
            <span style={{ fontVariantNumeric: 'tabular-nums' }}>{done}/{tasks.length}</span>
          </span>
        )}
      </div>
    </div>
  )
}

// MARK: - Belge

function DocumentView({ page, accent, canEdit }: { page: Rec; accent: string; canEdit: boolean }) {
  const blocks = sortedBlocks(page)
  const [menu, setMenu] = useState<{ block: string; anchor: HTMLElement } | null>(null)
  const [drag, setDrag] = useState<{ id: string; target: string | null; y: number } | null>(null)
  const listRef = useRef<HTMLDivElement>(null)
  const focus = useUI((s) => s.focus)

  /** ⋮⋮ tutamacı: sürükle → taşı, tıkla → menü */
  const onHandleDown = (e: RPointerEvent<HTMLButtonElement>, block: Rec) => {
    if (!canEdit || e.button !== 0) return
    e.preventDefault()
    const startY = e.clientY
    const handle = e.currentTarget
    let dragging = false
    const targetAt = (y: number) => {
      const rows = [...(listRef.current?.querySelectorAll<HTMLElement>('[data-block]') ?? [])]
      for (const row of rows) {
        const r = row.getBoundingClientRect()
        if (y < r.top + r.height / 2) return { id: row.dataset.block!, y: row.offsetTop }
      }
      const last = rows.at(-1)
      return { id: null, y: last ? last.offsetTop + last.offsetHeight : 0 }
    }
    const move = (ev: PointerEvent) => {
      if (!dragging && Math.abs(ev.clientY - startY) > 4) dragging = true
      if (dragging) { const t = targetAt(ev.clientY); setDrag({ id: block.uuid, target: t.id, y: t.y }) }
    }
    const up = (ev: PointerEvent) => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
      document.body.classList.remove('grabbing')
      if (!dragging) { setMenu({ block: block.uuid, anchor: handle }); return }
      const t = targetAt(ev.clientY)
      setDrag(null)
      if (t.id === block.uuid) return
      const target = t.id ? get('Block', t.id) ?? null : null
      moveBlock(get('Block', block.uuid)!, target)
    }
    document.body.classList.add('grabbing')
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }

  const insertWithSlash = (block: Rec) => {
    if (bk.kind(block) === 'text' && !bk.text(block)) {
      update(block, { text_: '/' })
      focusBlock(block.uuid, 'end')
    } else {
      const created = addBlock(page, 'text', '/', block, { indent: bk.indent(block) })
      focusBlock(created.uuid, 'end')
    }
  }

  const append = (kind: BlockKind) => {
    const last = blocks.at(-1)
    const block = last && bk.kind(last) === 'text' && !bk.text(last) ? last : addBlock(page, 'text', '', last ?? null)
    update(block, { indent: 0 })
    if (kind === 'text') focusBlock(block.uuid, 'start')
    else perform({ type: 'convert', kind }, block)
  }

  const appendIfNeeded = () => {
    if (!canEdit) return
    const last = blocks.at(-1)
    if (last && hasText(bk.kind(last)) && bk.kind(last) !== 'image' && !bk.text(last)) focusBlock(last.uuid, 'start')
    else focusBlock(addBlock(page, 'text', '', last ?? null, { indent: 0 }).uuid, 'start')
  }

  const menuBlock = menu ? get('Block', menu.block) : undefined

  return (
    <div className="editor-scroll" onClick={(e) => { if (e.target === e.currentTarget) appendIfNeeded() }}>
      <div className="doc" style={{ maxWidth: 760 + GUTTER + MARGIN * 2, paddingLeft: Math.max(MARGIN - GUTTER, 4) + GUTTER, paddingRight: MARGIN, paddingTop: MARGIN / 1.5 }}>
        <div style={{ paddingBottom: 18 }}><Header page={page} /></div>
        <div ref={listRef} style={{ position: 'relative' }}>
          {blocks.map((block) => (
            <div
              key={block.uuid}
              data-block={block.uuid}
              className={`blk-wrap${focus === block.uuid ? ' focused' : ''}`}
              style={{ zIndex: focus === block.uuid ? 2 : undefined, opacity: drag?.id === block.uuid ? 0.4 : 1 }}
            >
              {canEdit && (
                <div className={`gutter${menu?.block === block.uuid ? ' open' : ''}`} style={{ left: -GUTTER + bk.indent(block) * 22 - 4, top: gutterTop(bk.kind(block)) }}>
                  <button title="Altına blok ekle" onMouseDown={(e) => e.preventDefault()} onClick={() => insertWithSlash(block)}><Plus size={15} strokeWidth={2} /></button>
                  <button className="handle" title="Sürükle: taşı · Tıkla: menü" aria-label="Blok menüsü" data-testid="block-handle" onPointerDown={(e) => onHandleDown(e, block)}>
                    <GripVertical size={14} strokeWidth={2.4} />
                  </button>
                </div>
              )}
              <BlockRow block={block} blocks={blocks} accent={accent} documentMode canEdit={canEdit} />
              <div className="slash-anchor" style={{ paddingLeft: bk.indent(block) * 22 }}><SlashMenu blockID={block.uuid} /></div>
            </div>
          ))}
          {drag && <div className="drop-line" style={{ top: drag.y - 2, background: accent }} />}
        </div>
        {canEdit && (
          <button className="add-block" data-testid="add-block" onClick={(e) => showMenu(e.currentTarget, insertMenu(append, INSERTABLE))}>
            <Plus size={14} /> Blok ekle
          </button>
        )}
        <div className="doc-tail" onClick={appendIfNeeded} />
      </div>
      {menu && menuBlock && (
        <BlockMenu
          block={menuBlock}
          anchor={menu.anchor}
          onClose={() => setMenu(null)}
          onOp={(op) => perform(op, menuBlock)}
          onComment={() => openSheet({ type: 'comments', block: menuBlock.uuid })}
          onDelete={() => { remove(menuBlock); touch(page) }}
        />
      )}
    </div>
  )
}

/** Tutamaç ilk satırın ortasında dursun */
function gutterTop(kind: BlockKind): number {
  switch (kind) {
    case 'heading': return 18
    case 'heading2': return 12
    case 'heading3': return 7
    case 'divider': return 4
    case 'code': return 6
    default: return 0
  }
}

// MARK: - Tuval

/** Sürükleme bitince bırakılan yerdeki "tıklama" tuvalde yeni kutu açmasın */
function suppressClick() {
  const stop = (e: MouseEvent) => { e.stopPropagation(); e.preventDefault() }
  window.addEventListener('click', stop, { capture: true, once: true })
  setTimeout(() => window.removeEventListener('click', stop, { capture: true }), 50)
}

function CanvasView({ page, accent, canEdit }: { page: Rec; accent: string; canEdit: boolean }) {
  const blocks = sortedBlocks(page)
  const focus = useUI((s) => s.focus)
  const previousFocus = useRef<string | null>(null)

  // Belgeden gelen ya da MCP ile eklenen (konumsuz) blokları yerleşmişlerin altına diz
  useEffect(() => {
    const all = sortedBlocks(get('Page', page.uuid))
    const unplaced = all.filter((b) => !b.f.isPlaced)
    if (!unplaced.length || !canEdit) return
    const placed = all.filter((b) => b.f.isPlaced)
    let y = placed.length ? Math.max(...placed.map((b) => Number(b.f.y) + estimatedCanvasHeight(b))) + 16 : 8
    for (const b of unplaced) {
      update(b, { width: Math.max(Number(b.f.width ?? 280), CARD_WIDTH), x: MARGIN - 12 + bk.indent(b) * 22, y, isPlaced: true }, { stamp: true })
      y += estimatedCanvasHeight(get('Block', b.uuid)!) + 6
    }
  }, [blocks.length, page.uuid, canEdit])

  // Boş bırakılan metin kutularını temizle
  useEffect(() => {
    const old = previousFocus.current
    previousFocus.current = focus
    if (!old || old === focus || useFormat.getState().editingToolbar) return
    const b = get('Block', old)
    if (b && b.parent === page.uuid && bk.kind(b) === 'text' && !bk.text(b).trim()) remove(b)
  }, [focus, page.uuid])

  const tap = (e: React.MouseEvent<HTMLDivElement>) => {
    if (e.target !== e.currentTarget || !canEdit) return
    if (useUI.getState().focus) {
      ;(document.activeElement as HTMLElement | null)?.blur()
      useUI.setState({ focus: null })
      return
    }
    const r = e.currentTarget.getBoundingClientRect()
    const block = addBlock(page, 'text', '', null, { x: e.clientX - r.left - 14, y: e.clientY - r.top - 14, isPlaced: true })
    focusBlock(block.uuid, 'start')
  }

  const drawing = !!page.f.drawing_
  return (
    <div className="canvas-scroll">
      <div style={{ width: 3000 }}>
        <div style={{ padding: `24px ${MARGIN}px 8px`, maxWidth: 600 + MARGIN * 2 }}><Header page={page} /></div>
        <div className="canvas-area" style={{ width: 3000, height: 2400 }} onClick={tap} data-testid="canvas">
          {blocks.map((b) => <CanvasCard key={b.uuid} block={b} blocks={blocks} accent={accent} canEdit={canEdit} focused={focus === b.uuid} />)}
          {drawing && (
            <div className="drawing-note" style={{ left: MARGIN, top: 8 }} title="Apple Pencil çizimleri Mac / iPad'de görünür; burada korunur ve silinmez.">
              <Pencil size={12} /> Bu sayfada iPad / Mac çizimi var — Windows'ta gösterilemiyor, korunuyor
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

function CanvasCard({ block, blocks, accent, canEdit, focused }: { block: Rec; blocks: Rec[]; accent: string; canEdit: boolean; focused: boolean }) {
  const [drag, setDrag] = useState<{ dx: number; dy: number } | null>(null)
  const [resize, setResize] = useState(0)
  const [hover, setHover] = useState(false)
  const active = hover || focused || !!drag

  const track = useCallback((e: RPointerEvent, onMove: (dx: number, dy: number) => void, onEnd: (dx: number, dy: number) => void) => {
    if (!canEdit || e.button !== 0) return
    e.preventDefault()
    e.stopPropagation()
    const sx = e.clientX, sy = e.clientY
    const move = (ev: PointerEvent) => onMove(ev.clientX - sx, ev.clientY - sy)
    const up = (ev: PointerEvent) => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
      document.body.classList.remove('grabbing')
      suppressClick()
      onEnd(ev.clientX - sx, ev.clientY - sy)
    }
    document.body.classList.add('grabbing')
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }, [canEdit])

  const x = Number(block.f.x ?? 60), y = Number(block.f.y ?? 60), width = Number(block.f.width ?? 280)
  const style: CSSProperties = {
    left: x + (drag?.dx ?? 0), top: y + (drag?.dy ?? 0), width: Math.max(140, width + resize),
    ['--blk-accent' as string]: accent,
  }
  return (
    <div
      className={`card${active ? ' active' : ''}${focused ? ' focused' : ''}${drag ? ' dragging' : ''}`}
      style={style}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
    >
      <div
        className="card-handle"
        data-testid="canvas-handle"
        onPointerDown={(e) => track(e, (dx, dy) => setDrag({ dx, dy }), (dx, dy) => {
          setDrag(null)
          if (dx || dy) { update(get('Block', block.uuid)!, { x: x + dx, y: y + dy, isPlaced: true }); touch(get('Page', block.parent)) }
        })}
      >
        <span />
      </div>
      <div className="card-body">
        <BlockRow block={block} blocks={blocks} accent={accent} documentMode={false} canEdit={canEdit} />
      </div>
      <div
        className="card-resize"
        onPointerDown={(e) => track(e, (dx) => setResize(dx), (dx) => {
          setResize(0)
          if (dx) update(get('Block', block.uuid)!, { width: Math.max(140, width + dx) })
        })}
      >
        <MoveHorizontal size={11} strokeWidth={2.6} />
      </div>
    </div>
  )
}
