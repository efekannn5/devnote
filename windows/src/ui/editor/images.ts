// Görsel ekleme (Mac'teki ImageImport + ImageCodec): en uzun kenar 1600 px, JPEG, ~900 KB sınırı.

import { native } from '../../lib/native'
import { report } from '../../lib/errors'
import { get, remove, recKey, update, useStore, type AssetRef, type Rec } from '../../model/store'
import { addBlock, bk, pg, sortedBlocks } from '../../model/ops'

async function compress(blob: Blob): Promise<string | null> {
  const bitmap = await createImageBitmap(blob).catch(() => null)
  if (!bitmap) return null
  const scale = Math.min(1, 1600 / Math.max(bitmap.width, bitmap.height))
  const canvas = document.createElement('canvas')
  canvas.width = Math.max(1, Math.round(bitmap.width * scale))
  canvas.height = Math.max(1, Math.round(bitmap.height * scale))
  const ctx = canvas.getContext('2d')!
  ctx.fillStyle = '#fff'
  ctx.fillRect(0, 0, canvas.width, canvas.height)
  ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height)
  let quality = 0.78
  for (;;) {
    const data = canvas.toDataURL('image/jpeg', quality)
    const base64 = data.slice(data.indexOf(',') + 1)
    if (base64.length * 0.75 <= 900_000 || quality < 0.35) return base64
    quality -= 0.12
  }
}

/** Görseli sayfaya ekle; oluşan blok döner */
export async function addImage(page: Rec, blob: Blob, after: Rec | null): Promise<Rec | null> {
  const base64 = await compress(blob)
  if (!base64) { report('Görsel', 'Görsel okunamadı'); return null }
  const canvas = pg.layout(page) === 'canvas'
  const n = sortedBlocks(page).length
  const block = addBlock(page, 'image', '', after, canvas
    ? { width: 320, x: 40 + (n % 6) * 24, y: 20 + (n % 6) * 24, isPlaced: true }
    : {})
  const name = `${recKey(block)}-imageData_`
  await native.assetWrite(name, base64)
  // Senkron görseli yüklesin
  update(get('Block', block.uuid)!, { imageData_: { local: name, pending: true } satisfies AssetRef })
  return block
}

export async function addImages(page: Rec, files: Blob[], after: Rec | null, replacing: Rec | null = null) {
  let anchor = after
  for (const file of files) anchor = (await addImage(page, file, anchor)) ?? anchor
  const r = replacing && get('Block', replacing.uuid)
  if (r && anchor?.uuid !== r.uuid && bk.kind(r) === 'text' && !bk.text(r)) remove(r)
}

/** Dosya seçici (Mac'te Fotoğraf… / Dosyadan Görsel…) */
export function pickImages(): Promise<File[]> {
  return new Promise((resolve) => {
    const input = document.createElement('input')
    input.type = 'file'
    input.accept = 'image/*'
    input.multiple = true
    input.onchange = () => resolve([...(input.files ?? [])])
    input.addEventListener('cancel', () => resolve([]))
    input.click()
  })
}

/** Ekrandaki adres (diskteki dosya) */
const urlCache = new Map<string, string>()
export async function imageURL(asset: AssetRef | undefined): Promise<string | null> {
  if (!asset?.local) return null
  const cached = urlCache.get(asset.local)
  if (cached) return cached
  const url = await native.assetURL(asset.local)
  if (url) urlCache.set(asset.local, url)
  return url
}

/** Çoğaltılan görsel bloğu kendi dosyasını alsın (biri silinince diğeri bozulmasın) */
export async function copyImage(from: Rec, to: Rec) {
  const asset = from.f.imageData_ as AssetRef | undefined
  if (!asset?.local) return
  const base64 = await native.assetRead(asset.local)
  if (!base64) return
  const name = `${recKey(to)}-imageData_`
  await native.assetWrite(name, base64)
  const current = useStore.getState().recs[recKey(to)]
  if (current) update(current, { imageData_: { local: name, pending: true } })
}
