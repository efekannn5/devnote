// Ortak arayüz parçaları: macOS tarzı menüler, açılır pencere, sheet, ilerleme halkası, avatar, göreli tarih.

import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { create } from 'zustand'
import { Check, ChevronRight, type LucideIcon } from 'lucide-react'
import { useStore } from '../model/store'

/** Veri değişince yeniden çiz */
export function useVersion() { return useStore((s) => s.version) }

// MARK: - Menü

export type MenuEntry =
  | { label: string; icon?: LucideIcon | ReactNode; onClick?: () => void; danger?: boolean; disabled?: boolean; checked?: boolean; shortcut?: string; submenu?: MenuEntry[] }
  | 'sep'
  | { section: string }

interface MenuState { items: MenuEntry[] | null; x: number; y: number; minWidth?: number; onClose?: () => void }
const useMenu = create<MenuState>(() => ({ items: null, x: 0, y: 0 }))

/** Menüyü fare konumunda (sağ tık) ya da bir öğenin altında aç */
export function showMenu(at: { x: number; y: number } | HTMLElement | DOMRect, items: MenuEntry[], opts: { minWidth?: number; onClose?: () => void } = {}) {
  let x: number, y: number
  if (at instanceof HTMLElement || at instanceof DOMRect) {
    const r = at instanceof HTMLElement ? at.getBoundingClientRect() : at
    x = r.left; y = r.bottom + 4
  } else { x = at.x; y = at.y }
  useMenu.getState().onClose?.()
  useMenu.setState({ items, x, y, ...opts })
}
export function closeMenu() {
  const { onClose } = useMenu.getState()
  useMenu.setState({ items: null, onClose: undefined })
  onClose?.()
}

function renderIcon(icon: LucideIcon | ReactNode | undefined) {
  if (!icon) return <span style={{ width: 14 }} />
  if (typeof icon === 'function' || (typeof icon === 'object' && icon && '$$typeof' in icon && 'render' in (icon as object))) {
    const Icon = icon as LucideIcon
    return <Icon size={14} strokeWidth={1.8} />
  }
  return icon as ReactNode
}

function MenuList({ items, x, y, minWidth, depth = 0 }: { items: MenuEntry[]; x: number; y: number; minWidth?: number; depth?: number }) {
  const ref = useRef<HTMLDivElement>(null)
  const [pos, setPos] = useState({ x, y })
  const [sub, setSub] = useState<{ index: number; rect: DOMRect } | null>(null)
  const [active, setActive] = useState(-1)
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    const r = el.getBoundingClientRect()
    let nx = x, ny = y
    if (nx + r.width > window.innerWidth - 8) nx = depth ? x - r.width - (minWidth ?? 0) : window.innerWidth - r.width - 8
    if (ny + r.height > window.innerHeight - 8) ny = Math.max(8, window.innerHeight - r.height - 8)
    setPos({ x: Math.max(8, nx), y: ny })
  }, [x, y, depth, minWidth])

  const actionable = items.map((it, i) => (typeof it === 'object' && 'label' in it && !it.disabled ? i : -1)).filter((i) => i >= 0)
  useEffect(() => {
    if (depth) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault()
        const idx = actionable.indexOf(active)
        const next = e.key === 'ArrowDown' ? actionable[(idx + 1) % actionable.length] : actionable[(idx - 1 + actionable.length) % actionable.length]
        setActive(next ?? -1)
      } else if (e.key === 'Enter' && active >= 0) {
        e.preventDefault()
        const it = items[active]
        if (typeof it === 'object' && 'label' in it && it.onClick) { closeMenu(); it.onClick() }
      }
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  })

  return (
    <>
      <div ref={ref} className="menu" style={{ left: pos.x, top: pos.y, minWidth }} onMouseDown={(e) => e.preventDefault()}>
        {items.map((it, i) => {
          if (it === 'sep') return <div key={i} className="menu-sep" />
          if ('section' in it) return <div key={i} className="menu-label">{it.section}</div>
          return (
            <div
              key={i}
              className={`menu-item${it.danger ? ' danger' : ''}${it.disabled ? ' disabled' : ''}${active === i || sub?.index === i ? ' active' : ''}`}
              onMouseEnter={(e) => {
                setActive(i)
                setSub(it.submenu ? { index: i, rect: (e.currentTarget as HTMLElement).getBoundingClientRect() } : null)
              }}
              onClick={() => {
                if (it.submenu || it.disabled) return
                closeMenu()
                it.onClick?.()
              }}
            >
              {it.checked ? <Check size={14} strokeWidth={2.2} /> : renderIcon(it.icon)}
              <span>{it.label}</span>
              {it.shortcut && <span className="k">{it.shortcut}</span>}
              {it.submenu && <span className="k"><ChevronRight size={12} /></span>}
            </div>
          )
        })}
      </div>
      {sub && (() => {
        const it = items[sub.index]
        return typeof it === 'object' && 'submenu' in it && it.submenu
          ? <MenuList items={it.submenu} x={sub.rect.right + 2} y={sub.rect.top - 5} minWidth={sub.rect.width} depth={depth + 1} />
          : null
      })()}
    </>
  )
}

export function MenuHost() {
  const { items, x, y, minWidth } = useMenu()
  useEffect(() => {
    if (!items) return
    const close = (e: MouseEvent) => { if (!(e.target as HTMLElement).closest('.menu')) closeMenu() }
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopPropagation(); closeMenu() } }
    window.addEventListener('mousedown', close, true)
    window.addEventListener('keydown', esc, true)
    window.addEventListener('blur', closeMenu)
    window.addEventListener('resize', closeMenu)
    return () => {
      window.removeEventListener('mousedown', close, true)
      window.removeEventListener('keydown', esc, true)
      window.removeEventListener('blur', closeMenu)
      window.removeEventListener('resize', closeMenu)
    }
  }, [items])
  if (!items) return null
  return createPortal(<MenuList items={items} x={x} y={y} minWidth={minWidth} />, document.body)
}

// MARK: - Açılır pencere (popover)

export function Popover({ anchor, onClose, children, className = '', placement = 'below' }: {
  anchor: HTMLElement | DOMRect | null; onClose: () => void; children: ReactNode; className?: string; placement?: 'below' | 'right'
}) {
  const ref = useRef<HTMLDivElement>(null)
  const [pos, setPos] = useState<{ x: number; y: number } | null>(null)
  useLayoutEffect(() => {
    if (!anchor || !ref.current) return
    const a = anchor instanceof HTMLElement ? anchor.getBoundingClientRect() : anchor
    const r = ref.current.getBoundingClientRect()
    let x = placement === 'right' ? a.right + 6 : a.left
    let y = placement === 'right' ? a.top - 8 : a.bottom + 6
    if (x + r.width > window.innerWidth - 8) x = window.innerWidth - r.width - 8
    if (y + r.height > window.innerHeight - 8) y = Math.max(8, (placement === 'right' ? window.innerHeight : a.top - 6) - r.height - (placement === 'right' ? 8 : 0))
    setPos({ x: Math.max(8, x), y })
  }, [anchor, placement])
  useEffect(() => {
    const down = (e: MouseEvent) => {
      const t = e.target as HTMLElement
      if (ref.current?.contains(t) || t.closest('.menu')) return
      onClose()
    }
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    window.addEventListener('mousedown', down, true)
    window.addEventListener('keydown', esc)
    return () => { window.removeEventListener('mousedown', down, true); window.removeEventListener('keydown', esc) }
  }, [onClose])
  if (!anchor) return null
  return createPortal(
    <div ref={ref} className={`popover ${className}`} style={{ left: pos?.x ?? -9999, top: pos?.y ?? -9999 }}>{children}</div>,
    document.body,
  )
}

// MARK: - Sheet (Mac'teki .sheet)

export function Sheet({ onClose, width = 440, children, title, actions }: {
  onClose: () => void; width?: number; children: ReactNode; title?: ReactNode; actions?: ReactNode
}) {
  useEffect(() => {
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape' && !document.querySelector('.menu')) onClose() }
    window.addEventListener('keydown', esc)
    return () => window.removeEventListener('keydown', esc)
  }, [onClose])
  return createPortal(
    <div className="sheet-backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose() }}>
      <div className="sheet" style={{ width }}>
        {title && <div className="sheet-head">{title}</div>}
        {children}
        {actions && <div className="sheet-actions">{actions}</div>}
      </div>
    </div>,
    document.body,
  )
}

// MARK: - Küçük parçalar

export function ProgressRing({ progress, tint, size = 18 }: { progress: number; tint: string; size?: number }) {
  const stroke = 2.5
  const r = (size - stroke) / 2
  const c = 2 * Math.PI * r
  return (
    <svg className="progress-ring" width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={tint} strokeOpacity={0.18} strokeWidth={stroke} />
      <circle
        cx={size / 2} cy={size / 2} r={r} fill="none" stroke={tint} strokeWidth={stroke} strokeLinecap="round"
        strokeDasharray={c} strokeDashoffset={c * (1 - progress)} transform={`rotate(-90 ${size / 2} ${size / 2})`}
        style={{ transition: 'stroke-dashoffset .35s cubic-bezier(.2,.9,.3,1)' }}
      />
    </svg>
  )
}

export function Avatar({ name, tint, size = 32 }: { name: string; tint: string; size?: number }) {
  const initials = name.split(' ').filter(Boolean).slice(0, 2).map((w) => w[0]).join('').toLocaleUpperCase('tr')
  return (
    <div className="avatar" style={{ width: size, height: size, fontSize: size * 0.38, background: `linear-gradient(180deg, color-mix(in srgb, ${tint} 85%, white), ${tint})` }}>
      {initials || '?'}
    </div>
  )
}

const rtf = new Intl.RelativeTimeFormat('tr', { numeric: 'auto' })
/** SwiftUI .relative(presentation: .named) karşılığı: "dün", "2 saat önce", "3 gün sonra" */
export function relative(ms: number): string {
  const diff = (ms - Date.now()) / 1000
  const abs = Math.abs(diff)
  if (abs < 45) return 'şimdi'
  if (abs < 3600) return rtf.format(Math.round(diff / 60), 'minute')
  if (abs < 86_400) return rtf.format(Math.round(diff / 3600), 'hour')
  if (abs < 7 * 86_400) return rtf.format(Math.round(diff / 86_400), 'day')
  if (abs < 30 * 86_400) return rtf.format(Math.round(diff / (7 * 86_400)), 'week')
  if (abs < 365 * 86_400) return rtf.format(Math.round(diff / (30 * 86_400)), 'month')
  return rtf.format(Math.round(diff / (365 * 86_400)), 'year')
}

/** "11 Ekim 14:05" (Mac: .dateTime.day().month(.wide).hour().minute()) */
export function dayMonthTime(ms: number): string {
  return new Date(ms).toLocaleString('tr-TR', { day: 'numeric', month: 'long', hour: '2-digit', minute: '2-digit' })
}

export const hexAlpha = (hex: string, alpha: number) => {
  const h = hex.replace('#', '')
  const full = h.length === 3 ? h.split('').map((c) => c + c).join('') : h.slice(0, 6)
  return `#${full}${Math.round(alpha * 255).toString(16).padStart(2, '0')}`
}
