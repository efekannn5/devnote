// İşletim sistemi işleri (Tauri komutları). Tarayıcıda (geliştirme / arayüz testleri) çalışırken
// localStorage'a düşer; böylece arayüz Tauri olmadan da denenebilir.

import { invoke, convertFileSrc } from '@tauri-apps/api/core'

export const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window

const memoryAssets = new Map<string, string>()

export const native = {
  async read(name: string): Promise<string | null> {
    if (isTauri) return invoke<string | null>('store_read', { name })
    return localStorage.getItem(`devnote:${name}`)
  },
  async write(name: string, content: string): Promise<void> {
    if (isTauri) return invoke('store_write', { name, content })
    try { localStorage.setItem(`devnote:${name}`, content) } catch { /* tarayıcı kotası: önemsiz */ }
  },
  async remove(name: string): Promise<void> {
    if (isTauri) return invoke('store_delete', { name })
    localStorage.removeItem(`devnote:${name}`)
  },

  /** Görsel kaydet; gösterilebilir adres döner */
  async assetWrite(name: string, base64: string): Promise<string> {
    if (isTauri) return convertFileSrc(await invoke<string>('asset_write', { name, base64 }))
    memoryAssets.set(name, base64)
    return `data:image/jpeg;base64,${base64}`
  },
  async assetURL(name: string): Promise<string | null> {
    if (isTauri) {
      const path = await invoke<string | null>('asset_path', { name })
      return path ? convertFileSrc(path) : null
    }
    const data = memoryAssets.get(name)
    return data ? `data:image/jpeg;base64,${data}` : null
  },
  async assetRead(name: string): Promise<string | null> {
    if (isTauri) return invoke<string | null>('asset_read', { name })
    return memoryAssets.get(name) ?? null
  },
  async assetDelete(name: string): Promise<void> {
    if (isTauri) return invoke('asset_delete', { name })
    memoryAssets.delete(name)
  },

  async secretGet(key: string): Promise<string | null> {
    if (isTauri) return invoke<string | null>('secret_get', { key })
    return sessionStorage.getItem(`devnote-secret:${key}`)
  },
  async secretSet(key: string, value: string): Promise<void> {
    if (isTauri) return invoke('secret_set', { key, value })
    sessionStorage.setItem(`devnote-secret:${key}`, value)
  },
  async secretDelete(key: string): Promise<void> {
    if (isTauri) return invoke('secret_delete', { key })
    sessionStorage.removeItem(`devnote-secret:${key}`)
  },

  async openURL(url: string): Promise<void> {
    if (isTauri) {
      const { openUrl } = await import('@tauri-apps/plugin-opener')
      return openUrl(url)
    }
    window.open(url, '_blank', 'noopener')
  },

  /** Ağ isteği: Tauri'de Rust tarafından yapılır (tarayıcı CORS kısıtı yok) */
  async fetch(url: string, init?: RequestInit): Promise<Response> {
    if (isTauri) {
      const { fetch: tauriFetch } = await import('@tauri-apps/plugin-http')
      return tauriFetch(url, init)
    }
    return fetch(url, init)
  },

  async notify(title: string, body: string): Promise<void> {
    if (!isTauri) {
      if ('Notification' in window && Notification.permission === 'granted') new Notification(title, { body })
      return
    }
    const n = await import('@tauri-apps/plugin-notification')
    let granted = await n.isPermissionGranted()
    if (!granted) granted = (await n.requestPermission()) === 'granted'
    if (granted) n.sendNotification({ title, body })
  },
}
