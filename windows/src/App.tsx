// Uygulama kabuğu: kenar çubuğu | not listesi | editör (Mac'teki NavigationSplitView), giriş ekranı, uyarılar.

import { useCallback, useState, type PointerEvent as RPointerEvent } from 'react'
import { AlertTriangle, CheckCircle2, NotebookText, X } from 'lucide-react'
import { Sidebar } from './ui/Sidebar'
import { PageList } from './ui/PageList'
import { PageEditor } from './ui/editor/PageEditor'
import { SheetHost } from './ui/Sheets'
import { MenuHost } from './ui/common'
import { WindowControls } from './ui/WindowControls'
import { dismissToast, openSheet, openTask, useUI } from './ui/state'
import { get } from './model/store'
import { setSettings, useSettings } from './lib/settings'
import { dismissBanner, useErrors } from './lib/errors'
import { useSync } from './sync/engine'
import { signIn } from './sync/auth'
import { ck } from './sync/cloudkit'

export default function App() {
  const page = useUI((s) => s.page)
  const listWidth = useSettings((s) => s.listWidth)
  const [resizing, setResizing] = useState(false)
  const pageExists = page && get('Page', page)

  const startResize = useCallback((e: RPointerEvent, which: 'sidebar' | 'list') => {
    e.preventDefault()
    const start = e.clientX
    const initial = which === 'sidebar' ? useSettings.getState().sidebarWidth : useSettings.getState().listWidth
    const [min, max] = which === 'sidebar' ? [200, 300] : [240, 380]
    setResizing(true)
    const move = (ev: PointerEvent) => {
      const width = Math.round(Math.min(max, Math.max(min, initial + ev.clientX - start)))
      setSettings(which === 'sidebar' ? { sidebarWidth: width } : { listWidth: width })
    }
    const up = () => {
      setResizing(false)
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }, [])

  return (
    <div className={`app${resizing ? ' resizing' : ''}`}>
      <Sidebar />
      <div className="splitter" onPointerDown={(e) => startResize(e, 'sidebar')} />
      <div className="column list-column" style={{ width: listWidth }}>
        <PageList />
      </div>
      <div className="splitter" onPointerDown={(e) => startResize(e, 'list')} />
      {pageExists ? <PageEditor key={page} pageID={page} /> : <EmptyDetail />}
      <ErrorBanner />
      <Toasts />
      <SheetHost />
      <MenuHost />
      <Login />
    </div>
  )
}

function EmptyDetail() {
  return (
    <div className="column detail-column">
      <div className="toolbar" data-tauri-drag-region>
        <div className="spacer" data-tauri-drag-region />
        <WindowControls />
      </div>
      <div className="empty" data-tauri-drag-region>
        <NotebookText size={44} strokeWidth={1.2} />
        <div className="big">Bir not seç</div>
        <div>Soldan bir sayfa seç ya da yenisini oluştur.</div>
      </div>
    </div>
  )
}

/** Ekranın üstünden kayan hata uyarısı (Mac'teki ErrorBanner) */
function ErrorBanner() {
  const banner = useErrors((s) => s.banner)
  if (!banner) return null
  setTimeout(() => { if (useErrors.getState().banner?.id === banner.id) dismissBanner() }, 6000)
  return (
    <div className="banner" key={banner.id}>
      <AlertTriangle size={20} color="#FF9500" fill="#FF9500" stroke="var(--popover)" />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontWeight: 600 }}>{banner.area} hatası</div>
        <div className="clamp3" style={{ color: 'var(--text-2)', fontSize: 12 }}>{banner.message}</div>
        <div style={{ color: 'var(--text-3)', fontSize: 11 }}>Kaydedildi · uygulamaya devam edebilirsin</div>
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 6, alignItems: 'flex-end' }}>
        <button className="link-btn" onClick={dismissBanner} aria-label="Kapat"><X size={12} strokeWidth={3} /></button>
        <button className="link-btn" style={{ color: 'var(--accent)', fontWeight: 600 }} onClick={() => { dismissBanner(); openSheet({ type: 'errors' }) }}>Ayrıntı</button>
      </div>
    </div>
  )
}

function Toasts() {
  const toasts = useUI((s) => s.toasts)
  return (
    <div className="toasts">
      {toasts.map((t) => (
        <div key={t.id} className="toast" onClick={() => { if (t.taskID) openTask(t.taskID); dismissToast(t.id) }}>
          <img src="/logo.png" alt="" width={32} height={32} style={{ borderRadius: 8, flex: 'none' }} />
          <div style={{ minWidth: 0 }}>
            <div className="t">{t.title}</div>
            <div className="b clamp3">{t.body}</div>
          </div>
        </div>
      ))}
    </div>
  )
}

/** İlk açılış: iCloud girişi (Apple'ın giriş sayfası tarayıcıda açılır) */
function Login() {
  const sync = useSync()
  const [dismissed, setDismissed] = useState(() => sessionStorage.getItem('devnote-offline') === '1')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [token, setToken] = useState('')
  if (sync.signedIn || dismissed) return null
  const needsToken = !ck.hasAPIToken

  const start = async () => {
    setBusy(true)
    setError(null)
    try { await signIn() } catch (e) { setError(e instanceof Error ? e.message : String(e)) } finally { setBusy(false) }
  }

  return (
    <div className="login" data-tauri-drag-region>
      <div style={{ position: 'absolute', top: 0, right: 12 }}><WindowControls /></div>
      <div className="login-card">
        <img src="/logo.png" alt="DevNote" />
        <h1>DevNote</h1>
        <p>Mac ve iPhone'daki notların, görevlerin ve ekibin burada. Devam etmek için Apple hesabınla iCloud'a giriş yap.</p>
        {needsToken ? (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8, width: '100%' }}>
            <p style={{ fontSize: 12 }}>Önce CloudKit API anahtarını gir (bir kez):</p>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="field" placeholder="CloudKit API anahtarı" value={token} onChange={(e) => setToken(e.target.value)} />
              <button className="btn primary" disabled={!token.trim()} onClick={async () => { await ck.setAPIToken(token); setToken(''); useSync.setState({ needsAPIToken: false }) }}>Kaydet</button>
            </div>
          </div>
        ) : (
          <button className="btn primary apple" disabled={busy} onClick={() => void start()}>
           {busy ? 'Tarayıcıda giriş bekleniyor…' : 'Apple ile giriş yap'}
          </button>
        )}
        {busy && <p style={{ fontSize: 12 }}>Tarayıcıda Apple'ın giriş sayfası açıldı. Girişi tamamla; tarayıcı “DevNote açılsın mı?” diye sorarsa “Aç”a bas. Uygulama kendiliğinden bağlanır.</p>}
        {error && <p style={{ color: '#FF3B30', fontSize: 12 }}>{error}</p>}
        <p style={{ fontSize: 11, color: 'var(--text-3)', display: 'flex', gap: 6, alignItems: 'center' }}>
          <CheckCircle2 size={12} /> Şifren yalnızca Apple'a gider; DevNote görmez.
        </p>
        <button className="link-btn" style={{ fontSize: 12 }} onClick={() => { sessionStorage.setItem('devnote-offline', '1'); setDismissed(true) }}>
          Şimdilik iCloud olmadan devam et
        </button>
      </div>
    </div>
  )
}
