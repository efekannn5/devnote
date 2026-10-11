import { createRoot } from 'react-dom/client'
import './styles.css'
import App from './App'
import { loadStore } from './model/store'
import { loadSettings } from './lib/settings'
import { report } from './lib/errors'
import { isTauri } from './lib/native'
import { ck } from './sync/cloudkit'
import { engine, useSync } from './sync/engine'
import { startNotifier } from './sync/notifier'
import { startMcp } from './mcp/tools'
import { listenForCallback } from './sync/auth'

// Yakalanmamış hatalar uygulamayı durdurmasın; kaydedilsin (Mac'teki ErrorReporter)
window.addEventListener('error', (e) => report('Uygulama', e.error ?? e.message))
window.addEventListener('unhandledrejection', (e) => report('Uygulama', e.reason))

// Sağ tık: tarayıcı menüsü yerine uygulamanın menüleri (metin alanlarında kopyala/yapıştır kalsın)
document.addEventListener('contextmenu', (e) => {
  const t = e.target as HTMLElement
  if (!t.closest('input, textarea, [contenteditable="true"]')) e.preventDefault()
})

async function boot() {
  await loadSettings()
  await loadStore()
  await ck.load()
  if (!isTauri && new URLSearchParams(location.search).has('demo')) {
    const { seedDemo } = await import('./demo')
    seedDemo()
  }
  createRoot(document.getElementById('root')!).render(<App />)
  await engine.start()
  await listenForCallback()
  startNotifier()
  void startMcp()
  if (ck.isSignedIn) await engine.connect()
  else useSync.setState({ text: ck.hasAPIToken ? 'iCloud oturumu kapalı' : 'CloudKit API anahtarı gerekli', needsAPIToken: !ck.hasAPIToken })
}

void boot()
