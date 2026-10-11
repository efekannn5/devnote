// Tarayıcıdan iCloud girişi (masaüstü uygulamaları için Apple'ın önerdiği yol).
//  1) Oturumsuz istek → Apple'ın giriş adresi (redirectURL); varsayılan tarayıcıda açılır
//  2) Kullanıcı Apple'ın sayfasında giriş yapar (şifre yalnızca Apple'a gider)
//  3) Apple tarayıcıyı cloudkit-icloud.com.efekan.devnote://callback?ckWebAuthToken=… adresine yönlendirir;
//     Windows bu bağlantıyı DevNote'a verir (kayıt kurulumda kullanıcıya özel yazılır, yönetici izni gerekmez)
//  4) Belirteç Windows Kimlik Bilgisi Yöneticisi'nde saklanır; sonraki açılışlarda giriş gerekmez

import { ck } from './cloudkit'
import { engine, useSync } from './engine'
import { native, isTauri } from '../lib/native'
import { report } from '../lib/errors'

export const CALLBACK_URL = 'cloudkit-icloud.com.efekan.devnote://callback'

let waiting: { resolve: (token: string) => void; reject: (e: Error) => void } | null = null

/** Bağlantıdaki belirteç ("+" boşluğa dönüşmesin diye ham sorgudan okunur) */
function tokenFrom(url: string): string | null {
  const raw = url.split(/[?#]/).slice(1).join('&')
  for (const pair of raw.split('&')) {
    const [key, ...rest] = pair.split('=')
    if (key === 'ckWebAuthToken' || key === 'ckSession') return decodeURIComponent(rest.join('=').replace(/\+/g, '%2B'))
  }
  return null
}

async function handleURLs(urls: string[] | null) {
  for (const url of urls ?? []) {
    if (!url.startsWith('cloudkit-icloud.com.efekan.devnote:')) continue
    const token = tokenFrom(url)
    if (!token) { waiting?.reject(new Error('Apple girişi tamamlanmadı')); continue }
    if (waiting) { waiting.resolve(token); continue }
    // Uygulama girişi beklemiyorken gelen bağlantı (ör. giriş sırasında uygulama yeniden açıldı)
    try {
      await ck.setWebToken(token)
      await engine.connect()
    } catch (error) { report('iCloud girişi', error) }
  }
}

/** Uygulama açılışında: dönüş bağlantılarını dinle (soğuk açılışta gelen bağlantı dahil) */
export async function listenForCallback() {
  if (!isTauri) return
  const { onOpenUrl, getCurrent } = await import('@tauri-apps/plugin-deep-link')
  await onOpenUrl((urls) => void handleURLs(urls))
  await handleURLs(await getCurrent())
}

export async function signIn(): Promise<void> {
  useSync.setState({ text: 'Tarayıcıda Apple girişi bekleniyor…' })
  const redirectUrl = await ck.signInURL()
  waiting?.reject(new Error('Yeni giriş başlatıldı'))
  const token = new Promise<string>((resolve, reject) => {
    waiting = { resolve, reject }
    setTimeout(() => reject(new Error('Giriş zaman aşımına uğradı')), 10 * 60_000)
  })
  await native.openURL(redirectUrl)
  try {
    await ck.setWebToken(await token)
  } finally {
    waiting = null
  }
  await engine.connect()
}

export async function signOut() {
  await ck.signOut()
  await engine.reset()
  useSync.setState({ signedIn: false, text: 'iCloud oturumu kapalı' })
}
