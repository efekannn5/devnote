// Windows pencere düğmeleri (simge durumuna küçült / ekranı kapla / kapat). Pencere kenarlıksız;
// araç çubukları sürükleme alanıdır (data-tauri-drag-region), çift tıklayınca ekranı kaplar.

import { useEffect, useState } from 'react'
import { isTauri } from '../lib/native'

async function win() {
  const { getCurrentWindow } = await import('@tauri-apps/api/window')
  return getCurrentWindow()
}

export function WindowControls() {
  const [maximized, setMaximized] = useState(false)
  useEffect(() => {
    if (!isTauri) return
    let off: (() => void) | undefined
    void win().then(async (w) => {
      setMaximized(await w.isMaximized())
      off = await w.onResized(async () => setMaximized(await w.isMaximized()))
    })
    return () => off?.()
  }, [])
  return (
    <div className="caption">
      <button aria-label="Simge durumuna küçült" onClick={() => void win().then((w) => w.minimize())}>
        <svg width="10" height="10" viewBox="0 0 10 10"><path d="M0 5h10" stroke="currentColor" strokeWidth="1" /></svg>
      </button>
      <button aria-label={maximized ? 'Önceki boyut' : 'Ekranı kapla'} onClick={() => void win().then((w) => w.toggleMaximize())}>
        {maximized
          ? <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" strokeWidth="1"><path d="M2.5 0.5h7v7" /><rect x="0.5" y="2.5" width="7" height="7" /></svg>
          : <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" strokeWidth="1"><rect x="0.5" y="0.5" width="9" height="9" /></svg>}
      </button>
      <button className="close" aria-label="Kapat" onClick={() => void win().then((w) => w.close())}>
        <svg width="10" height="10" viewBox="0 0 10 10" stroke="currentColor" strokeWidth="1"><path d="M0 0l10 10M10 0L0 10" /></svg>
      </button>
    </div>
  )
}
