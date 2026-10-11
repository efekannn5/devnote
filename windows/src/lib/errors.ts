// Mac'teki ErrorReporter: hatalar günlüğe yazılır; kalıcı olmayanlar yalnızca kaydedilir, diğerleri
// kenar çubuğundaki uyarıda görünür.

import { create } from 'zustand'

export interface ErrorEntry {
  id: number
  date: number
  area: string
  message: string
  silent: boolean
}

interface State {
  recent: ErrorEntry[]
  log: ErrorEntry[]
  banner: ErrorEntry | null
}

export const useErrors = create<State>(() => ({ recent: [], log: [], banner: null }))

let next = 1

export function report(area: string, error: unknown, opts: { silent?: boolean } = {}) {
  const message = error instanceof Error ? error.message : typeof error === 'string' ? error : JSON.stringify(error)
  const entry: ErrorEntry = { id: next++, date: Date.now(), area, message, silent: !!opts.silent }
  console.warn(`[${area}]`, message)
  useErrors.setState((s) => ({
    log: [entry, ...s.log].slice(0, 300),
    recent: entry.silent ? s.recent : [entry, ...s.recent].slice(0, 20),
    banner: entry.silent ? s.banner : entry,
  }))
}

export function clearRecent() { useErrors.setState({ recent: [], banner: null }) }
export function dismissBanner() { useErrors.setState({ banner: null }) }
