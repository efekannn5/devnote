// "/" menüsü, ⋮⋮ blok menüsü ve Word gibi üst biçim çubuğu (Mac'teki BlockEditing.swift)

import { useEffect, useRef, useState, type ReactNode } from 'react'
import {
  ArrowDown, ArrowUp, Ban, Bold, ChevronDown, Code, CopyPlus, Eraser, Highlighter, IndentDecrease, IndentIncrease, Italic,
  Link, MessageSquare, Minus, Plus, Strikethrough, Trash2, Underline, Undo2, X,
} from 'lucide-react'
import { get, type Rec } from '../../model/store'
import { bk, shiftBlock, type BlockKind } from '../../model/ops'
import { KIND_ICONS } from '../icons'
import { Popover, showMenu } from '../common'
import {
  INSERTABLE, KIND_SHORTCUTS, KIND_TITLES, TEXT_KINDS, duplicate, hasText, pickKind, slashPick, slashResults, useSlash, type EditorOp,
} from './blockOps'
import {
  HIGHLIGHT_COLORS, INLINE_FORMATS, SIZE_PRESETS, SIZE_RANGE, TEXT_COLORS, applyLink, formatWholeBlock, sendFormat, useFormat,
  type InlineFormat,
} from './format'

// MARK: - "/" menüsü

export function SlashMenu({ blockID }: { blockID: string }) {
  const session = useSlash((s) => s.session)
  const listRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const row = listRef.current?.querySelector('.slash-row.active') as HTMLElement | null
    row?.scrollIntoView({ block: 'nearest' })
  }, [session?.highlighted])
  if (!session || session.blockID !== blockID) return null
  const results = slashResults(session.query)
  return (
    <div className="popover slash slash-inline" onMouseDown={(e) => e.preventDefault()} data-testid="slash-menu">
      <div className="q">{session.query ? `“${session.query}”` : 'Blok türü'}</div>
      {results.length === 0 ? (
        <div style={{ padding: 12, color: 'var(--text-2)' }}>Sonuç yok</div>
      ) : (
        <div className="rows" ref={listRef} style={{ height: Math.min(results.length * 38 + 4, 320) }}>
          {results.map((kind, i) => <SlashRow key={kind} kind={kind} active={i === session.highlighted} />)}
        </div>
      )}
    </div>
  )
}

function SlashRow({ kind, active }: { kind: BlockKind; active: boolean }) {
  const Icon = KIND_ICONS[kind]
  return (
    <div className={`slash-row${active ? ' active' : ''}`} onClick={() => slashPick(kind)} aria-label={KIND_TITLES[kind]}>
      <span className="ic"><Icon size={15} strokeWidth={1.8} /></span>
      <span>{KIND_TITLES[kind]}</span>
      {KIND_SHORTCUTS[kind] && <span className="sc">{KIND_SHORTCUTS[kind]}</span>}
    </div>
  )
}

// MARK: - ⋮⋮ blok menüsü

export function BlockMenu({ block, anchor, onClose, onOp, onComment, onDelete }: {
  block: Rec; anchor: HTMLElement; onClose: () => void; onOp: (op: EditorOp) => void; onComment: () => void; onDelete: () => void
}) {
  const kind = bk.kind(block)
  const textual = hasText(kind) && kind !== 'image'
  const act = (fn: () => void) => { onClose(); fn() }
  return (
    <Popover anchor={anchor} onClose={onClose} placement="right">
      <div className="block-menu" data-testid="block-menu">
        {textual && (
          <Section title="Dönüştür">
            <div className="kind-grid">
              {TEXT_KINDS.map((k) => {
                const Icon = KIND_ICONS[k]
                return (
                  <button key={k} className={`kind-btn${k === kind ? ' on' : ''}`} onClick={() => act(() => onOp({ type: 'convert', kind: k }))}>
                    <Icon size={14} strokeWidth={1.8} /> {KIND_TITLES[k]}
                  </button>
                )
              })}
            </div>
          </Section>
        )}
        {textual && !!bk.text(block) && (
          <>
            <Section title="Yazı rengi">
              <Swatches colors={TEXT_COLORS} fill={false} apply={(hex) => act(() => formatWholeBlock(block.uuid, { type: 'color', color: hex }))} />
            </Section>
            <Section title="Arka plan">
              <Swatches colors={HIGHLIGHT_COLORS} fill apply={(hex) => act(() => formatWholeBlock(block.uuid, { type: 'highlight', color: hex }))} />
            </Section>
          </>
        )}
        <div className="menu-sep" style={{ margin: 0 }} />
        <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
          <Item icon={<MessageSquare size={15} />} label="Yorum" onClick={() => act(onComment)} />
          <Item icon={<CopyPlus size={15} />} label="Çoğalt" onClick={() => act(() => duplicate(block))} />
          <Item icon={<ArrowUp size={15} />} label="Yukarı taşı" onClick={() => act(() => shiftBlock(get('Block', block.uuid)!, -1))} />
          <Item icon={<ArrowDown size={15} />} label="Aşağı taşı" onClick={() => act(() => shiftBlock(get('Block', block.uuid)!, 1))} />
          {textual && <Item icon={<IndentIncrease size={15} />} label="Girinti artır" onClick={() => act(() => onOp({ type: 'indent', delta: 1 }))} />}
          {textual && <Item icon={<IndentDecrease size={15} />} label="Girinti azalt" onClick={() => act(() => onOp({ type: 'indent', delta: -1 }))} />}
          <Item icon={<Trash2 size={15} />} label="Sil" danger onClick={() => act(onDelete)} />
        </div>
      </div>
    </Popover>
  )
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return <div><div className="bm-title">{title}</div>{children}</div>
}

function Item({ icon, label, onClick, danger }: { icon: ReactNode; label: string; onClick: () => void; danger?: boolean }) {
  return <button className={`bm-item${danger ? ' danger' : ''}`} onClick={onClick}>{icon} {label}</button>
}

function Swatches({ colors, fill, apply }: { colors: { hex: string; title: string }[]; fill: boolean; apply: (hex: string | null) => void }) {
  return (
    <div className="swatches">
      <button className="swatch" style={{ border: 0, color: 'var(--text-2)' }} onClick={() => apply(null)} aria-label="Varsayılan"><Ban size={15} /></button>
      {colors.map((c) => (
        <button
          key={c.hex}
          className="swatch"
          title={c.title}
          aria-label={c.title}
          onClick={() => apply(c.hex)}
          style={fill ? { background: `color-mix(in srgb, ${c.hex} 45%, transparent)` } : { color: c.hex, fontSize: 15 }}
        >
          {fill ? '' : 'A'}
        </button>
      ))}
    </div>
  )
}

// MARK: - Biçim çubuğu

const FORMAT_ICONS: Record<InlineFormat, typeof Bold> = {
  bold: Bold, italic: Italic, underline: Underline, strikethrough: Strikethrough, code: Code, link: Link,
}

/** Odaktaki bloğun türü ("Metin ⌄") */
export function KindPicker() {
  const { blockID, kind } = useFormat()
  return (
    <button
      className="fb-btn"
      style={{ minWidth: 118, justifyContent: 'space-between' }}
      disabled={!blockID}
      onMouseDown={(e) => e.preventDefault()}
      onClick={(e) => blockID && showMenu(e.currentTarget, TEXT_KINDS.map((k) => ({
        label: KIND_TITLES[k], icon: KIND_ICONS[k], checked: k === kind, onClick: () => pickKind(blockID, k),
      })))}
      aria-label={`Blok türü: ${KIND_TITLES[kind]}`}
    >
      <span>{KIND_TITLES[kind]}</span>
      <ChevronDown size={12} strokeWidth={2.4} />
    </button>
  )
}

export function FormatToolbar() {
  const state = useFormat()
  const disabled = !state.blockID
  const [sizeText, setSizeText] = useState(String(state.pointSize))
  const [editingSize, setEditingSize] = useState(false)
  useEffect(() => { if (!editingSize) setSizeText(fmt(state.pointSize)) }, [state.pointSize, editingSize])
  const prevent = (e: React.MouseEvent) => e.preventDefault()

  const applySize = () => {
    const value = parseFloat(sizeText.replace(',', '.'))
    setEditingSize(false)
    useFormat.setState({ editingToolbar: false })
    if (!Number.isNaN(value)) sendFormat({ type: 'size', size: Math.min(Math.max(value, SIZE_RANGE[0]), SIZE_RANGE[1]) })
    else state.editor?.commands.focus()
  }

  return (
    <div className="format-bar" aria-disabled={disabled}>
      <KindPicker />
      <span className="sep" />
      {INLINE_FORMATS.map(({ id, title, shortcut }) => {
        const Icon = FORMAT_ICONS[id]
        const on = state[id]
        return (
          <button key={id} className={`fb-btn${on ? ' on' : ''}`} disabled={disabled} title={`${title} (${shortcut})`} aria-label={title}
            aria-pressed={on} onMouseDown={prevent} onClick={() => sendFormat({ type: 'toggle', format: id })}>
            <Icon size={15} strokeWidth={id === 'bold' ? 2.6 : 2} />
          </button>
        )
      })}
      <span className="sep" />
      <button className="fb-btn" disabled={disabled} title="Yazı rengi" aria-label="Yazı rengi" onMouseDown={prevent}
        onClick={(e) => showMenu(e.currentTarget, [
          ...TEXT_COLORS.map((c) => ({ label: c.title, icon: <span className="dot" style={{ background: c.hex, width: 10, height: 10 }} />, onClick: () => sendFormat({ type: 'color', color: c.hex }) })),
          'sep', { label: 'Varsayılan', icon: Undo2, onClick: () => sendFormat({ type: 'color', color: null }) },
        ])}>
        <span style={{ position: 'relative', fontWeight: 600, fontSize: 14, lineHeight: 1 }}>
          A<span style={{ position: 'absolute', left: -2, right: -2, bottom: -4, height: 3, borderRadius: 2, background: '#FF453A' }} />
        </span>
      </button>
      <div style={{ display: 'flex' }}>
        <button className="fb-btn" disabled={disabled} title="Arka plan rengi (tıkla: sarı, ok: renkler)" aria-label="Vurgula" onMouseDown={prevent}
          onClick={() => sendFormat({ type: 'highlight', color: '#FFD60A' })} style={{ paddingRight: 2 }}>
          <Highlighter size={15} />
        </button>
        <button className="fb-btn" disabled={disabled} aria-label="Vurgu renkleri" onMouseDown={prevent} style={{ minWidth: 14, padding: 0 }}
          onClick={(e) => showMenu(e.currentTarget, [
            ...HIGHLIGHT_COLORS.map((c) => ({ label: c.title, icon: <span className="dot" style={{ background: c.hex, width: 10, height: 10 }} />, onClick: () => sendFormat({ type: 'highlight', color: c.hex }) })),
            'sep', { label: 'Arka planı kaldır', icon: X, onClick: () => sendFormat({ type: 'highlight', color: null }) },
          ])}>
          <ChevronDown size={10} strokeWidth={2.6} />
        </button>
      </div>
      <span className="sep" />
      <button className="fb-btn" disabled={disabled} title="Küçült (Ctrl+-)" aria-label="Küçült" onMouseDown={prevent} onClick={() => sendFormat({ type: 'sizeStep', delta: -1 })}>
        <Minus size={14} />
      </button>
      <input
        className="size-field"
        value={sizeText}
        disabled={disabled}
        aria-label="Yazı boyutu (px)"
        data-testid="font-size-field"
        onFocus={() => { setEditingSize(true); useFormat.setState({ editingToolbar: true }) }}
        onBlur={() => { if (editingSize) applySize() }}
        onChange={(e) => setSizeText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter') { e.preventDefault(); applySize() }
          if (e.key === 'Escape') { setEditingSize(false); useFormat.setState({ editingToolbar: false }); state.editor?.commands.focus() }
        }}
      />
      <button className="fb-btn" disabled={disabled} title="Büyüt (Ctrl++)" aria-label="Büyüt" onMouseDown={prevent} onClick={() => sendFormat({ type: 'sizeStep', delta: 1 })}>
        <Plus size={14} />
      </button>
      <button className="fb-btn" disabled={disabled} aria-label="Hazır boyutlar" onMouseDown={prevent} style={{ minWidth: 18, padding: 0 }}
        onClick={(e) => showMenu(e.currentTarget, [
          ...SIZE_PRESETS.map((s) => ({ label: `${s} px`, onClick: () => sendFormat({ type: 'size', size: s }) })),
          'sep', { label: 'Normal boyut', onClick: () => sendFormat({ type: 'size', size: null }) },
        ])}>
        <ChevronDown size={10} strokeWidth={2.6} />
      </button>
      <span className="sep" />
      <button className="fb-btn" disabled={disabled} title="Biçimi temizle (Ctrl+\)" aria-label="Biçimi temizle" onMouseDown={prevent} onClick={() => sendFormat({ type: 'clear' })}>
        <Eraser size={15} />
      </button>
      {state.linkPrompt && <LinkPrompt initial={state.linkPrompt.href} />}
    </div>
  )
}

const fmt = (n: number) => (Math.round(n) === n ? String(n) : n.toFixed(1))

function LinkPrompt({ initial }: { initial: string }) {
  const [href, setHref] = useState(initial)
  const anchor = document.querySelector('[aria-label="Bağlantı"]') as HTMLElement | null
  return (
    <Popover anchor={anchor} onClose={() => applyLink(null)}>
      <form style={{ padding: 12, display: 'flex', gap: 8, width: 340 }} onSubmit={(e) => { e.preventDefault(); applyLink(href.trim() || null) }}>
        <input className="field" autoFocus value={href} onChange={(e) => setHref(e.target.value)} onFocus={(e) => e.currentTarget.select()} placeholder="https://" />
        <button className="btn primary" type="submit">Ekle</button>
      </form>
    </Popover>
  )
}

/** "+" ve sayfa sonundaki "Blok ekle" menüleri için tür listesi */
export function insertMenu(onPick: (kind: BlockKind) => void, kinds: BlockKind[] = INSERTABLE) {
  return kinds.map((k) => ({ label: KIND_TITLES[k], icon: KIND_ICONS[k], onClick: () => onPick(k) }))
}
