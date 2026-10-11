// Arayüz durumu: seçili liste / sayfa, odaktaki blok, açık sayfalar (sheet), bildirim kartları.

import { create } from 'zustand'
import { flushSync } from 'react-dom'
import { get } from '../model/store'

export type SidebarItem =
  | { type: 'all' } | { type: 'pinned' } | { type: 'openTasks' } | { type: 'assignedToMe' } | { type: 'aiCompleted' }
  | { type: 'notebook'; uuid: string }

export const SMART_TITLES: Record<string, string> = {
  all: 'Tüm Notlar', pinned: 'Sabitlenenler', openTasks: 'Açık Görevler', assignedToMe: 'Bana Atananlar', aiCompleted: 'AI Tamamladı',
}

export type Sheet =
  | { type: 'notebook'; uuid?: string }
  | { type: 'comments'; block: string }
  | { type: 'team'; notebook: string }
  | { type: 'errors' }
  | { type: 'settings' }
  | { type: 'image'; block: string }
  | { type: 'due'; block: string }

export interface Toast { id: number; title: string; body: string; taskID?: string }

interface UIState {
  sidebar: SidebarItem
  page: string | null
  search: string
  focus: string | null
  sheet: Sheet | null
  toasts: Toast[]
}

export const useUI = create<UIState>(() => ({
  sidebar: { type: 'all' }, page: null, search: '', focus: null, sheet: null, toasts: [],
}))

export const sameItem = (a: SidebarItem, b: SidebarItem) =>
  a.type === b.type && (a.type !== 'notebook' || (b.type === 'notebook' && a.uuid === b.uuid))

export function select(sidebar: SidebarItem) { useUI.setState({ sidebar, page: null }) }
export function openPage(uuid: string | null) { useUI.setState({ page: uuid }) }
export function openSheet(sheet: Sheet | null) { useUI.setState({ sheet }) }

/** Bildirimden / etkinlikten: görevin sayfasını aç ve göreve odaklan */
export function openTask(blockID: string) {
  const block = get('Block', blockID)
  if (!block?.parent) return
  useUI.setState({ sidebar: { type: 'all' }, page: block.parent, sheet: null })
  setTimeout(() => focusBlock(blockID, 'end'), 120)
}

let toastID = 1
export function toast(title: string, body: string, taskID?: string) {
  const t = { id: toastID++, title, body, taskID }
  useUI.setState((s) => ({ toasts: [...s.toasts, t].slice(-4) }))
  setTimeout(() => dismissToast(t.id), 7000)
}
export function dismissToast(id: number) { useUI.setState((s) => ({ toasts: s.toasts.filter((t) => t.id !== id) })) }

// MARK: - Odak

type Cursor = number | 'start' | 'end'
/** Odaklanabildiyse true döner (yok edilmiş editör false) */
type Focuser = (cursor: Cursor) => boolean
const focusers = new Map<string, Focuser>()
const pendingCursor = new Map<string, Cursor>()

/** Blok editörü kendini kaydeder; odak isteği bu fonksiyonla iletilir */
export function registerFocuser(id: string, fn: Focuser) {
  focusers.set(id, fn)
  const pending = pendingCursor.get(id)
  if (pending !== undefined && fn(pending)) pendingCursor.delete(id)
  return () => { if (focusers.get(id) === fn) focusers.delete(id) }
}

/** Bloğa odaklan; editör henüz oluşmadıysa oluşunca */
export function focusBlock(id: string, cursor: Cursor = 'end') {
  useUI.setState({ focus: id })
  const fn = focusers.get(id)
  // Hemen odaklan: hızlı yazarken sonraki tuş yeni satıra gitsin
  if (fn?.(cursor)) return
  pendingCursor.set(id, cursor)
  // Yeni blok henüz çizilmedi: hemen çiz (sonraki tuş eski satıra gitmesin), olmazsa birkaç kare dene
  try { flushSync(() => {}) } catch { /* çizim sırasında çağrıldı */ }
  const retry = (n: number) => {
    const p = pendingCursor.get(id)
    if (p === undefined) return
    if (focusers.get(id)?.(p)) { pendingCursor.delete(id); return }
    if (n > 0) requestAnimationFrame(() => retry(n - 1))
    else pendingCursor.delete(id)
  }
  retry(20)
}
