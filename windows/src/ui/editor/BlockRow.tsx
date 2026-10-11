// Tek bir bloğun görünümü (Mac'teki BlockRow): belge ve tuval ortak kullanır.

import { memo, useEffect, useState, type CSSProperties, type MouseEvent } from 'react'
import {
  ArrowDown, ArrowUp, Bell, Check, IndentDecrease, IndentIncrease, MessageSquare, Repeat, Sparkles, Trash2, User, UserPlus,
  Undo2, Image as ImageIcon,
} from 'lucide-react'
import { get, update, type AssetRef, type Rec } from '../../model/store'
import {
  assign, bk, commentsOf, deleteRec, listNumber, me, notebookOf, participants, setDone, setDue, shiftBlock, touch, type BlockKind,
} from '../../model/ops'
import { KIND_ICONS } from '../icons'
import { Popover, relative, showMenu, type MenuEntry } from '../common'
import { openSheet, useUI } from '../state'
import { BlockText } from './BlockText'
import { KIND_TITLES, TEXT_KINDS, perform, type EditorOp } from './blockOps'
import { imageURL } from './images'
import { engine } from '../../sync/engine'

interface Props {
  block: Rec
  blocks: Rec[]
  accent: string
  documentMode: boolean
  canEdit: boolean
  onOp?: (op: EditorOp) => void
}

export const BlockRow = memo(function BlockRow({ block, blocks, accent, documentMode, canEdit, onOp }: Props) {
  const kind = bk.kind(block)
  const indent = bk.indent(block)
  const op = onOp ?? ((o: EditorOp) => perform(o, block))
  const focused = useUI((s) => s.focus === block.uuid)
  const [dueAnchor, setDueAnchor] = useState<HTMLElement | null>(null)
  const comments = commentsOf(block)
  const style = { '--blk-accent': accent } as CSSProperties

  const onContext = (e: MouseEvent) => {
    e.preventDefault()
    showMenu({ x: e.clientX, y: e.clientY }, blockMenu(block, { canEdit, op, onDue: () => setDueAnchor(e.target as HTMLElement) }))
  }

  const showsChips = (kind === 'checklist' && (block.f.assigneeID_ || block.f.dueDate_)) || comments.length > 0

  if (kind === 'divider') {
    return (
      <div className="divider-blk" style={{ ...style, paddingLeft: indent * 22 }} onContextMenu={onContext}>
        <hr />
      </div>
    )
  }

  return (
    <div style={style} className="blk-outer">
      {kind === 'image' ? (
        <div onContextMenu={onContext} style={{ paddingLeft: indent * 22 }}>
          <ImageBlock block={block} canEdit={canEdit} documentMode={documentMode} />
        </div>
      ) : (
        <div
          className={`blk k-${kind}${bk.done(block) && kind === 'checklist' ? ' done' : ''}${focused ? ' focused' : ''}${documentMode ? ' doc' : ' free'}`}
          style={{ marginLeft: indent * 22 }}
          onContextMenu={onContext}
        >
          <Leading block={block} blocks={blocks} kind={kind} accent={accent} canEdit={canEdit} />
          <BlockText block={block} documentMode={documentMode} canEdit={canEdit} onOp={op} />
          {kind === 'checklist' && bk.done(block) && block.f.doneBy_ === 'ai' && <AIBadge note={block.f.doneNote_ as string | undefined} />}
        </div>
      )}
      {showsChips && (
        <div className="chips" style={{ paddingLeft: (kind === 'checklist' ? 27 : 0) + indent * 22 }}>
          {comments.length > 0 && (
            <button className="chip" style={tint('#0A84FF')} onClick={() => openSheet({ type: 'comments', block: block.uuid })} title="Yorumlar">
              <MessageSquare size={11} fill="currentColor" /> {comments.length}
            </button>
          )}
          {kind === 'checklist' && !!block.f.assigneeName_ && (
            <span className="chip" style={tint('#30D158')} title={block.f.assignedByName_ ? `Atayan: ${block.f.assignedByName_}` : ''}>
              <User size={11} fill="currentColor" />
              {block.f.assigneeName_ === 'Ben' || block.f.assigneeID_ === me().id ? 'Sana atandı' : `@${block.f.assigneeName_}`}
            </span>
          )}
          {kind === 'checklist' && !!block.f.dueDate_ && (
            <button
              className="chip"
              style={tint(Number(block.f.dueDate_) < Date.now() && !bk.done(block) ? '#FF3B30' : '#FF9500')}
              onClick={(e) => setDueAnchor(e.currentTarget)}
            >
              <Bell size={11} fill="currentColor" /> {relative(Number(block.f.dueDate_))}
            </button>
          )}
        </div>
      )}
      {dueAnchor && <DuePicker block={block} anchor={dueAnchor} onClose={() => setDueAnchor(null)} />}
    </div>
  )
})

const tint = (hex: string): CSSProperties => ({ background: `color-mix(in srgb, ${hex} 14%, transparent)`, color: hex })

function Leading({ block, blocks, kind, accent, canEdit }: { block: Rec; blocks: Rec[]; kind: BlockKind; accent: string; canEdit: boolean }) {
  switch (kind) {
    case 'checklist': {
      const done = bk.done(block)
      const ai = done && block.f.doneBy_ === 'ai'
      return (
        <span className="lead">
          <button
            className={`check${done ? ' on' : ''}${ai ? ' ai' : ''}`}
            disabled={!canEdit}
            onMouseDown={(e) => e.preventDefault()}
            onClick={() => setDone(block, !done, 'human')}
            aria-label={done ? 'Tamamlandı' : 'Tamamla'}
            style={done ? { background: ai ? 'var(--ai)' : accent, borderColor: ai ? 'var(--ai)' : accent } : undefined}
          >
            {done && <Check size={11} strokeWidth={3.2} />}
          </button>
        </span>
      )
    }
    case 'bullet': {
      const level = bk.indent(block) % 3
      return <span className="lead"><span className={`bullet-mark l${level}`} /></span>
    }
    case 'numbered':
      return <span className="lead"><span className="num-mark">{listNumber(block, blocks)}.</span></span>
    default:
      return null
  }
}

function AIBadge({ note }: { note?: string }) {
  const [anchor, setAnchor] = useState<HTMLElement | null>(null)
  return (
    <>
      <button className="ai-badge" title={note ?? 'Yapay zeka tarafından tamamlandı'} onClick={(e) => setAnchor(anchor ? null : e.currentTarget)}>
        <Sparkles size={10} /> AI
      </button>
      {anchor && (
        <Popover anchor={anchor} onClose={() => setAnchor(null)}>
          <div style={{ padding: 14, maxWidth: 280, display: 'flex', flexDirection: 'column', gap: 6 }}>
            <div style={{ color: 'var(--ai)', fontWeight: 600, display: 'flex', gap: 6, alignItems: 'center' }}><Sparkles size={14} /> Yapay zeka tamamladı</div>
            <div style={{ userSelect: 'text' }}>{note ?? 'Açıklama bırakılmadı.'}</div>
          </div>
        </Popover>
      )}
    </>
  )
}

/** Sağ tık menüsü (Mac'teki contextMenu) */
export function blockMenu(block: Rec, { canEdit, op, onDue }: { canEdit: boolean; op: (o: EditorOp) => void; onDue: () => void }): MenuEntry[] {
  const kind = bk.kind(block)
  const comments = commentsOf(block)
  const people = participants(notebookOf(block))
  const items: MenuEntry[] = [
    { label: comments.length ? `Yorumlar (${comments.length})…` : 'Yorum Yaz…', icon: MessageSquare, onClick: () => openSheet({ type: 'comments', block: block.uuid }) },
    'sep',
  ]
  if (kind === 'checklist' && canEdit) {
    if (people.length) {
      items.push({
        label: 'Ata', icon: UserPlus, submenu: [
          ...people.map((p) => ({ label: p.name, checked: p.id === block.f.assigneeID_, onClick: () => assign(block, p) })),
          ...(block.f.assigneeID_ ? ['sep' as const, { label: 'Atamayı kaldır', danger: true, onClick: () => assign(block, null) }] : []),
        ],
      })
    } else {
      items.push({ label: 'Ata (önce defteri paylaş)', icon: UserPlus, disabled: true })
    }
    items.push({ label: block.f.dueDate_ ? 'Hatırlatmayı Değiştir…' : 'Hatırlatma Ekle…', icon: Bell, onClick: onDue }, 'sep')
  }
  if (canEdit) {
    if (kind !== 'image') {
      items.push(
        { label: 'Dönüştür', icon: Repeat, submenu: TEXT_KINDS.map((k) => ({ label: KIND_TITLES[k], icon: KIND_ICONS[k], checked: k === kind, onClick: () => op({ type: 'convert', kind: k }) })) },
        { label: 'Girinti Artır', icon: IndentIncrease, onClick: () => update(block, { indent: Math.min(bk.indent(block) + 1, 6) }) },
        { label: 'Girinti Azalt', icon: IndentDecrease, onClick: () => update(block, { indent: Math.max(bk.indent(block) - 1, 0) }) },
      )
    }
    items.push(
      { label: 'Yukarı Taşı', icon: ArrowUp, onClick: () => shiftBlock(block, -1) },
      { label: 'Aşağı Taşı', icon: ArrowDown, onClick: () => shiftBlock(block, 1) },
    )
  }
  if (kind === 'checklist' && bk.done(block) && block.f.doneBy_ === 'ai') {
    items.push({ label: 'AI işaretini geri al', icon: Undo2, onClick: () => setDone(block, false, 'human') })
  }
  if (canEdit) items.push('sep', { label: 'Sil', icon: Trash2, danger: true, onClick: () => deleteRec(block) })
  return items
}

// MARK: - Hatırlatma

function toLocalInput(ms: number) {
  const d = new Date(ms)
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
}

function DuePicker({ block, anchor, onClose }: { block: Rec; anchor: HTMLElement; onClose: () => void }) {
  const initial = Number(block.f.dueDate_ ?? 0) || Date.now() + 3600_000
  const [value, setValue] = useState(toLocalInput(initial))
  return (
    <Popover anchor={anchor} onClose={onClose}>
      <div style={{ padding: 16, width: 300, display: 'flex', flexDirection: 'column', gap: 12 }}>
        <div style={{ fontWeight: 600, display: 'flex', gap: 6, alignItems: 'center' }}><Bell size={14} fill="currentColor" /> Hatırlatma</div>
        <input className="field" type="datetime-local" value={value} min={toLocalInput(Date.now())} onChange={(e) => setValue(e.target.value)} />
        <div style={{ display: 'flex', justifyContent: 'space-between' }}>
          <button className="btn danger" onClick={() => { setDue(block, null); onClose() }}>Kaldır</button>
          <button className="btn primary" onClick={() => {
            const ms = new Date(value).getTime()
            if (!Number.isNaN(ms)) setDue(block, ms)
            onClose()
          }}>Tamam</button>
        </div>
      </div>
    </Popover>
  )
}

export function DuePickerFor({ blockID, anchor, onClose }: { blockID: string; anchor: HTMLElement; onClose: () => void }) {
  const block = get('Block', blockID)
  return block ? <DuePicker block={block} anchor={anchor} onClose={onClose} /> : null
}

// MARK: - Görsel bloğu

function ImageBlock({ block, canEdit, documentMode }: { block: Rec; canEdit: boolean; documentMode: boolean }) {
  const asset = block.f.imageData_ as AssetRef | undefined
  const [url, setURL] = useState<string | null>(null)
  useEffect(() => {
    let alive = true
    void imageURL(asset).then((u) => { if (alive) setURL(u) })
    // Sunucuda var ama diskte yok: indir
    if (!asset?.local && asset?.remote) void engine.refreshAsset(block)
    return () => { alive = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [asset?.local, asset?.remote?.fileChecksum])
  return (
    <div style={{ padding: '4px 0' }}>
      {url ? (
        <img
          className="img-blk"
          src={url}
          alt={bk.text(block) || 'Görsel'}
          draggable={false}
          onClick={() => openSheet({ type: 'image', block: block.uuid })}
          style={{ maxHeight: documentMode ? 460 : undefined }}
        />
      ) : (
        <div className="img-placeholder">
          <ImageIcon size={16} /> {asset ? 'Görsel bekleniyor…' : 'Görsel açılamadı'}
        </div>
      )}
      <input
        className="img-caption"
        placeholder="Açıklama ekle"
        value={bk.text(block)}
        disabled={!canEdit}
        onChange={(e) => { update(block, { text_: e.target.value }); touch(get('Page', block.parent)) }}
      />
    </div>
  )
}
