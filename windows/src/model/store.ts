// Yerel veri deposu. Kayıtlar CloudKit kayıtlarıyla birebir aynı alanları taşır (bkz. schema.ts).
// Her değişiklik kalıcı olarak diske yazılır ve senkron motoruna bildirilir.

import { create } from 'zustand'
import { DEFAULT_OWNER, DEFAULTS, ENTITY_ORDER, PARENT, SCHEMA, type Entity } from './schema'
import { native } from '../lib/native'

/** Görsel / çizim alanı. `local`: diskteki dosya adı, `remote`: sunucudaki varlık (aynen geri gönderilir) */
export interface AssetRef {
  local?: string
  remote?: Record<string, unknown>
  /** Sunucuya henüz yüklenmedi */
  pending?: boolean
}

export interface Rec {
  entity: Entity
  uuid: string
  f: Record<string, unknown>
  zoneName: string
  zoneOwner: string
  /** Ebeveynin uuid'si (Page → Notebook, Block → Page, Comment → Block) */
  parent?: string
  /** CloudKit recordChangeTag (son bilinen sunucu sürümü) */
  tag?: string
}

export const keyOf = (entity: Entity, uuid: string) => `${entity}.${uuid}`
export const recKey = (r: Rec) => keyOf(r.entity, r.uuid)

export interface Person {
  id: string
  name: string
  isMe?: boolean
}

export interface ShareInfo {
  /** "sahip/bölge" */
  zone: string
  participants: (Person & { permission: string; accepted: boolean; owner: boolean })[]
  myPermission: 'READ_WRITE' | 'READ_ONLY' | 'NONE' | string
  title?: string
}

/** Senkrona bildirilen değişiklik */
export type Change =
  | { type: 'save'; key: string }
  | { type: 'delete'; rec: Rec }
  | { type: 'deleteZone'; zoneName: string; zoneOwner: string }

type Listener = (changes: Change[]) => void

interface State {
  recs: Record<string, Rec>
  /** Her değişiklikte artar: türetilmiş listeler buna göre yeniden hesaplanır */
  version: number
  me: Person
  shares: Record<string, ShareInfo>
  loaded: boolean
}

export const useStore = create<State>(() => ({
  recs: {},
  version: 0,
  me: { id: 'local-user', name: 'Ben', isMe: true },
  shares: {},
  loaded: false,
}))

const listeners = new Set<Listener>()
export function onLocalChange(fn: Listener) { listeners.add(fn); return () => listeners.delete(fn) }

// MARK: - Okuma

export function get(entity: Entity, uuid: string | undefined | null): Rec | undefined {
  if (!uuid) return undefined
  return useStore.getState().recs[keyOf(entity, uuid)]
}

export function field<T = unknown>(rec: Rec | undefined, name: string): T {
  const v = rec?.f[name]
  return (v === undefined || v === null ? DEFAULTS[name] ?? null : v) as T
}

// MARK: - Yazma

let pending: Change[] = []
let flushScheduled = false

function emit(change: Change) {
  pending.push(change)
  if (flushScheduled) return
  flushScheduled = true
  queueMicrotask(() => {
    flushScheduled = false
    const changes = pending
    pending = []
    listeners.forEach((fn) => fn(changes))
    schedulePersist()
  })
}

/** Kullanıcı değişikliği: alanları ayarla, değişiklik zamanını damgala, senkrona bildir */
export function update(rec: Rec, values: Record<string, unknown>, opts: { stamp?: boolean } = {}) {
  const state = useStore.getState()
  const key = recKey(rec)
  const current = state.recs[key] ?? rec
  let changed = false
  const f = { ...current.f }
  for (const [name, value] of Object.entries(values)) {
    const v = value === undefined ? null : value
    if (!sameValue(f[name], v)) { f[name] = v; changed = true }
  }
  if (!changed && state.recs[key]) return
  if (opts.stamp !== false) f.modifiedAt_ = Date.now()
  const next = { ...current, f }
  useStore.setState({ recs: { ...state.recs, [key]: next }, version: state.version + 1 })
  emit({ type: 'save', key })
}

/** Yeni kayıt ekle */
export function insert(rec: Rec) {
  const state = useStore.getState()
  rec.f.modifiedAt_ = Date.now()
  useStore.setState({ recs: { ...state.recs, [recKey(rec)]: rec }, version: state.version + 1 })
  emit({ type: 'save', key: recKey(rec) })
}

/** Kaydı ve alt kayıtlarını sil (Mac'teki cascade). Defter silinince bölgesi silinir. */
export function remove(rec: Rec, opts: { keepAssets?: boolean } = {}) {
  const state = useStore.getState()
  const recs = { ...state.recs }
  const removed: Rec[] = []
  const walk = (r: Rec) => {
    delete recs[recKey(r)]
    removed.push(r)
    const childEntity = (Object.keys(PARENT) as Entity[]).find((e) => PARENT[e] === r.entity)
    if (!childEntity) return
    for (const child of Object.values(state.recs)) {
      if (child.entity === childEntity && child.parent === r.uuid) walk(child)
    }
  }
  walk(rec)
  useStore.setState({ recs, version: state.version + 1 })
  for (const r of opts.keepAssets ? [] : removed) {
    for (const name of ['imageData_', 'drawing_']) {
      const asset = r.f[name] as AssetRef | undefined
      if (asset?.local) void native.assetDelete(asset.local)
    }
  }
  if (rec.entity === 'Notebook') {
    emit({ type: 'deleteZone', zoneName: rec.zoneName, zoneOwner: rec.zoneOwner })
  } else {
    removed.forEach((r) => emit({ type: 'delete', rec: r }))
  }
}

function sameValue(a: unknown, b: unknown): boolean {
  if (a === b) return true
  if (a == null && b == null) return true
  if (typeof a === 'object' && typeof b === 'object') return JSON.stringify(a) === JSON.stringify(b)
  return false
}

// MARK: - Buluttan / yapay zekadan gelen (senkrona geri bildirilmeyen) değişiklikler

/** Uzak kayıtları uygula. Son yazan kazanır: yerel kopya daha yeniyse alanlar ezilmez (etiket yine alınır). */
export function applyRemote(records: Rec[], deletions: { entity: Entity; uuid: string }[], zoneDeletions: string[] = []) {
  if (!records.length && !deletions.length && !zoneDeletions.length) return
  const state = useStore.getState()
  const recs = { ...state.recs }
  const sorted = [...records].sort((a, b) => ENTITY_ORDER[a.entity] - ENTITY_ORDER[b.entity])
  for (const remote of sorted) {
    const key = recKey(remote)
    const local = recs[key]
    if (local) {
      const localTime = Number(local.f.modifiedAt_ ?? 0)
      const remoteTime = Number(remote.f.modifiedAt_ ?? 0)
      if (localTime > remoteTime) { recs[key] = { ...local, tag: remote.tag, zoneName: remote.zoneName, zoneOwner: remote.zoneOwner }; continue }
      // Diskteki görseli koru (aynı sunucu varlığıysa yeniden indirme)
      const f = { ...remote.f }
      for (const name of ['imageData_', 'drawing_']) {
        const l = local.f[name] as AssetRef | undefined
        const r = f[name] as AssetRef | undefined
        if (l?.local && r?.remote && sameAsset(l.remote, r.remote)) f[name] = { ...r, local: l.local }
      }
      recs[key] = { ...remote, f }
    } else {
      recs[key] = remote
    }
  }
  for (const { entity, uuid } of deletions) delete recs[keyOf(entity, uuid)]
  for (const zone of zoneDeletions) {
    for (const [key, r] of Object.entries(recs)) if (`${r.zoneOwner}/${r.zoneName}` === zone) delete recs[key]
  }
  useStore.setState({ recs, version: state.version + 1 })
  schedulePersist()
}

function sameAsset(a?: Record<string, unknown>, b?: Record<string, unknown>) {
  return !!a && !!b && (a.fileChecksum ?? a.downloadURL) === (b.fileChecksum ?? b.downloadURL)
}

/** Senkron meta verisini (etiket) güncelle, değişiklik sayma */
export function setMeta(key: string, meta: Partial<Pick<Rec, 'tag'>> & { f?: Record<string, unknown> }) {
  const state = useStore.getState()
  const rec = state.recs[key]
  if (!rec) return
  const next = { ...rec, ...meta, f: meta.f ? { ...rec.f, ...meta.f } : rec.f }
  useStore.setState({ recs: { ...state.recs, [key]: next }, version: state.version + 1 })
  schedulePersist()
}

// MARK: - Kalıcılık

const FILE = 'store.json'
let persistTimer: ReturnType<typeof setTimeout> | undefined

function schedulePersist() {
  clearTimeout(persistTimer)
  persistTimer = setTimeout(persistNow, 400)
}

export async function persistNow() {
  clearTimeout(persistTimer)
  const { recs, me, shares } = useStore.getState()
  await native.write(FILE, JSON.stringify({ v: 1, recs: Object.values(recs), me, shares }))
}

export async function loadStore() {
  try {
    const text = await native.read(FILE)
    if (text) {
      const data = JSON.parse(text) as { recs: Rec[]; me?: Person; shares?: Record<string, ShareInfo> }
      const recs: Record<string, Rec> = {}
      for (const r of data.recs ?? []) if (SCHEMA[r.entity]) recs[recKey(r)] = r
      useStore.setState({ recs, me: data.me ?? useStore.getState().me, shares: data.shares ?? {}, version: 1, loaded: true })
      return
    }
  } catch (error) {
    console.error('Depo okunamadı', error)
    // Bozuk dosyayı kenara al; iCloud'dan yeniden gelir
    const text = await native.read(FILE)
    if (text) await native.write(`store-broken-${Date.now()}.json`, text)
  }
  useStore.setState({ loaded: true, version: 1 })
}

export function setMe(me: Person) {
  useStore.setState({ me })
  schedulePersist()
}

export function setShares(shares: Record<string, ShareInfo>) {
  useStore.setState((s) => ({ shares, version: s.version + 1 }))
  schedulePersist()
}

export function isMine(r: Pick<Rec, 'zoneOwner'>): boolean {
  const me = useStore.getState().me.id
  return r.zoneOwner === DEFAULT_OWNER || r.zoneOwner === me
}

/** Mac'teki uuidString gibi büyük harfli UUID */
export function newUUID(): string {
  return crypto.randomUUID().toUpperCase()
}

// Pencere kapanırken bekleyen yazımı kaçırma
window.addEventListener('beforeunload', () => { void persistNow() })
