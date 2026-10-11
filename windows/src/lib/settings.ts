// Uygulama ayarları (Mac'teki UserDefaults karşılığı)

import { create } from 'zustand'
import { native } from './native'

interface Settings {
  mcpEnabled: boolean
  mcpPort: number
  sidebarWidth: number
  listWidth: number
  notified: string[]
  primed: boolean
}

const FILE = 'settings.json'

export const useSettings = create<Settings>(() => ({
  mcpEnabled: true, mcpPort: 7337, sidebarWidth: 230, listWidth: 290, notified: [], primed: false,
}))

let timer: ReturnType<typeof setTimeout> | undefined

export async function loadSettings() {
  try {
    const text = await native.read(FILE)
    if (text) useSettings.setState(JSON.parse(text))
  } catch { /* varsayılanlar */ }
  useSettings.subscribe((s) => {
    clearTimeout(timer)
    timer = setTimeout(() => void native.write(FILE, JSON.stringify(s)), 300)
  })
}

export function setSettings(values: Partial<Settings>) { useSettings.setState(values) }
