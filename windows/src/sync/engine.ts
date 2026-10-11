// iCloud senkronu — Mac'teki CloudSync'in Windows karşılığı.
//  - Her yerel değişiklik ~150 ms içinde gönderilir (records/modify, "update" + recordChangeTag).
//  - Uygulama açıkken 2 sn'de bir (arka planda 15 sn) değişiklikler çekilir (changes/database → changes/zone).
//  - Her defter kendi bölgesinde (nb-<UUID>); kayıt adı "<Entity>.<UUID>"; çakışmada modifiedAt_ yeni olan kazanır.
//  - "update" yalnızca gönderilen alanları değiştirir: Windows'un bilmediği alanlar (ör. gelecekte eklenenler) silinmez.

import { create } from 'zustand'
import { ck, CKError, type CKParticipant, type CKRecord, type Database, type ZoneID } from './cloudkit'
import { DEFAULT_OWNER, ENTITIES, ENTITY_ORDER, SCHEMA, type Entity } from '../model/schema'
import {
  applyRemote, get, keyOf, onLocalChange, recKey, setMe, setMeta, setShares, useStore,
  type AssetRef, type Change, type Rec, type ShareInfo,
} from '../model/store'
import { native } from '../lib/native'
import { report } from '../lib/errors'

interface SyncStatus {
  text: string
  signedIn: boolean
  busy: boolean
  lastSync: number | null
  needsAPIToken: boolean
}

export const useSync = create<SyncStatus>(() => ({
  text: 'iCloud\'a bağlanıyor…', signedIn: false, busy: false, lastSync: null, needsAPIToken: false,
}))

interface PersistedState {
  dbTokens: Partial<Record<Database, string>>
  zoneTokens: Record<string, string>
  dirty: string[]
  deletes: Rec[]
  zoneDeletes: { zoneName: string; zoneOwner: string }[]
}

const STATE_FILE = 'sync-state.json'
const ASSET_FIELDS = ['imageData_', 'drawing_']

const zoneKey = (zoneName: string, zoneOwner: string) => `${zoneOwner}/${zoneName}`
const dbFor = (zoneOwner: string): Database => (zoneOwner === DEFAULT_OWNER || zoneOwner === useStore.getState().me.id ? 'private' : 'shared')
const zoneIDFor = (zoneName: string, zoneOwner: string): ZoneID =>
  dbFor(zoneOwner) === 'private' ? { zoneName } : { zoneName, ownerRecordName: zoneOwner }

class Engine {
  private state: PersistedState = { dbTokens: {}, zoneTokens: {}, dirty: [], deletes: [], zoneDeletes: [] }
  private dirty = new Set<string>()
  private sendTimer: ReturnType<typeof setTimeout> | undefined
  private sending = false
  private fetching = false
  private pollTimer: ReturnType<typeof setInterval> | undefined
  private tick = 0
  private lastRemoteChange = 0
  private retries = new Map<string, number>()
  private downloads = new Set<string>()
  private started = false
  private sharesCache: Record<string, ShareInfo> = {}

  async start() {
    if (this.started) return
    this.started = true
    try {
      const text = await native.read(STATE_FILE)
      if (text) this.state = { ...this.state, ...JSON.parse(text) }
    } catch (error) { report('iCloud', error, { silent: true }) }
    this.dirty = new Set(this.state.dirty)
    this.sharesCache = { ...useStore.getState().shares }

    // Hiç gönderilmemiş kayıtlar (iCloud'a bağlanmadan önce oluşanlar)
    for (const rec of Object.values(useStore.getState().recs)) if (!rec.tag) this.dirty.add(recKey(rec))

    onLocalChange((changes) => this.capture(changes))
    ck.onSignedOut = () => {
      useSync.setState({ signedIn: false, text: 'iCloud oturumu sona erdi — yeniden giriş yap' })
    }
    this.pollTimer = setInterval(() => this.pollIfDue(), 2000)
    window.addEventListener('focus', () => void this.fetchNow())
    window.addEventListener('online', () => { void this.fetchNow(); this.scheduleSend() })
  }

  /** Giriş yapıldıktan sonra: kimliği al, her şeyi çek, bekleyenleri gönder */
  async connect() {
    try {
      const user = await ck.currentUser()
      const me = useStore.getState().me
      if (user.userRecordName && me.id !== user.userRecordName) setMe({ id: user.userRecordName, name: 'Ben', isMe: true })
      useSync.setState({ signedIn: true, text: 'iCloud senkronu açık' })
      await this.fetchNow()
      this.scheduleSend(0)
    } catch (error) {
      this.handleError('iCloud bağlantısı', error)
    }
  }

  private persist() {
    this.state.dirty = [...this.dirty]
    void native.write(STATE_FILE, JSON.stringify(this.state))
  }

  /** Oturum kapatılınca: senkron durumu ve yerel kopyalar silinir (başka hesapla karışmasın) */
  async reset() {
    this.state = { dbTokens: {}, zoneTokens: {}, dirty: [], deletes: [], zoneDeletes: [] }
    this.dirty.clear()
    await native.remove(STATE_FILE)
  }

  // MARK: - Yerel değişiklikleri kuyruğa al

  private capture(changes: Change[]) {
    for (const change of changes) {
      if (change.type === 'save') this.dirty.add(change.key)
      else if (change.type === 'delete') {
        this.dirty.delete(recKey(change.rec))
        // Hiç gönderilmemiş kaydı silmeye gerek yok
        if (change.rec.tag) this.state.deletes.push(change.rec)
      } else if (change.type === 'deleteZone') {
        const prefix = zoneKey(change.zoneName, change.zoneOwner)
        for (const key of [...this.dirty]) {
          const rec = useStore.getState().recs[key]
          if (!rec || zoneKey(rec.zoneName, rec.zoneOwner) === prefix) this.dirty.delete(key)
        }
        this.state.deletes = this.state.deletes.filter((r) => zoneKey(r.zoneName, r.zoneOwner) !== prefix)
        this.state.zoneDeletes.push({ zoneName: change.zoneName, zoneOwner: change.zoneOwner })
        delete this.state.zoneTokens[prefix]
      }
    }
    this.persist()
    this.scheduleSend()
  }

  scheduleSend(delay = 150) {
    clearTimeout(this.sendTimer)
    this.sendTimer = setTimeout(() => void this.send(), delay)
  }

  // MARK: - Gönder

  private async send() {
    if (!ck.isSignedIn || this.sending) { if (this.sending) this.scheduleSend(400); return }
    if (!this.dirty.size && !this.state.deletes.length && !this.state.zoneDeletes.length) return
    this.sending = true
    useSync.setState({ busy: true })
    try {
      await this.sendZoneDeletes()
      await this.sendDeletes()
      await this.sendSaves()
    } catch (error) {
      this.handleError('iCloud gönderme', error)
    } finally {
      this.sending = false
      useSync.setState({ busy: false })
      this.persist()
    }
  }

  private async sendZoneDeletes() {
    const list = this.state.zoneDeletes
    this.state.zoneDeletes = []
    for (const zone of list) {
      try {
        await ck.modifyZones(dbFor(zone.zoneOwner), [{ operationType: 'delete', zone: { zoneID: zoneIDFor(zone.zoneName, zone.zoneOwner) } }])
      } catch (error) {
        if (error instanceof CKError && (error.code === 'ZONE_NOT_FOUND' || error.code === 'NOT_FOUND')) continue
        if (error instanceof CKError && error.code === 'NETWORK') { this.state.zoneDeletes.push(zone); throw error }
        report('iCloud defter silme', error)
      }
    }
  }

  private async sendDeletes() {
    const groups = new Map<string, Rec[]>()
    for (const rec of this.state.deletes) {
      const key = zoneKey(rec.zoneName, rec.zoneOwner)
      groups.set(key, [...(groups.get(key) ?? []), rec])
    }
    this.state.deletes = []
    for (const recs of groups.values()) {
      const { zoneName, zoneOwner } = recs[0]
      for (let i = 0; i < recs.length; i += 200) {
        const chunk = recs.slice(i, i + 200)
        try {
          await ck.modifyRecords(dbFor(zoneOwner), zoneIDFor(zoneName, zoneOwner), chunk.map((r) => ({
            operationType: 'forceDelete', record: { recordName: `${r.entity}.${r.uuid}`, recordType: r.entity },
          })))
        } catch (error) {
          if (error instanceof CKError && error.code === 'NETWORK') { this.state.deletes.push(...chunk); throw error }
          if (!(error instanceof CKError && error.code === 'ZONE_NOT_FOUND')) report('iCloud silme', error)
        }
      }
    }
  }

  private async sendSaves() {
    const recs = useStore.getState().recs
    const groups = new Map<string, Rec[]>()
    for (const key of this.dirty) {
      const rec = recs[key]
      if (!rec) { this.dirty.delete(key); continue }
      if (!rec.zoneName) { this.dirty.delete(key); continue }
      const zk = zoneKey(rec.zoneName, rec.zoneOwner)
      groups.set(zk, [...(groups.get(zk) ?? []), rec])
    }
    for (const list of groups.values()) {
      list.sort((a, b) => ENTITY_ORDER[a.entity] - ENTITY_ORDER[b.entity])
      const { zoneName, zoneOwner } = list[0]
      const db = dbFor(zoneOwner)
      const zoneID = zoneIDFor(zoneName, zoneOwner)
      // Yeni defter: önce bölgesi
      if (db === 'private' && list.some((r) => r.entity === 'Notebook' && !r.tag)) await this.ensureZone(zoneName)
      for (let i = 0; i < list.length; i += 100) {
        await this.saveChunk(db, zoneID, list.slice(i, i + 100))
      }
    }
  }

  private async ensureZone(zoneName: string) {
    try {
      await ck.modifyZones('private', [{ operationType: 'create', zone: { zoneID: { zoneName } } }])
    } catch (error) {
      if (!(error instanceof CKError && error.code === 'EXISTS')) throw error
    }
  }

  private async saveChunk(db: Database, zoneID: ZoneID, chunk: Rec[]) {
    const sentAt = new Map<string, unknown>()
    const operations = []
    for (const rec of chunk) {
      const fields = await this.toFields(rec, db, zoneID)
      if (!fields) continue
      sentAt.set(recKey(rec), rec.f.modifiedAt_)
      operations.push({
        operationType: rec.tag ? 'update' : 'create',
        record: { recordName: `${rec.entity}.${rec.uuid}`, recordType: rec.entity, recordChangeTag: rec.tag, fields },
      })
    }
    if (!operations.length) return
    let result: { records: CKRecord[] }
    try {
      result = await ck.modifyRecords(db, zoneID, operations)
    } catch (error) {
      if (error instanceof CKError && error.code === 'ZONE_NOT_FOUND' && db === 'private') {
        await this.ensureZone(zoneID.zoneName)
        result = await ck.modifyRecords(db, zoneID, operations)
      } else throw error
    }
    let retry = false
    for (const [index, saved] of (result.records ?? []).entries()) {
      const op = operations[index]
      const key = keyOf(op.record.recordType as Entity, op.record.recordName!.split('.').slice(1).join('.'))
      const current = useStore.getState().recs[key]
      if (!saved.serverErrorCode) {
        setMeta(key, { tag: saved.recordChangeTag })
        // Gönderim sırasında yeniden değiştiyse kuyrukta kalsın
        if (current && current.f.modifiedAt_ === sentAt.get(key)) this.dirty.delete(key)
        this.retries.delete(key)
        continue
      }
      retry = (await this.resolveFailure(db, zoneID, key, saved)) || retry
    }
    if (retry) this.scheduleSend(600)
  }

  /** Kayıt hatası; tekrar denenecekse true */
  private async resolveFailure(db: Database, zoneID: ZoneID, key: string, failure: CKRecord): Promise<boolean> {
    const tries = (this.retries.get(key) ?? 0) + 1
    this.retries.set(key, tries)
    if (tries > 4) {
      this.dirty.delete(key)
      report('iCloud kayıt', `${key}: ${failure.serverErrorCode} ${failure.reason ?? ''}`)
      return false
    }
    switch (failure.serverErrorCode) {
      case 'CONFLICT':
      case 'EXISTS': {
        // Sunucuda daha yeni sürüm var: daha yeniyse uygula, değilse etiketini alıp bizimkini yeniden gönder
        let server = failure.serverRecord
        if (!server) server = (await ck.lookup(db, zoneID, [failure.recordName ?? key])).records?.[0]
        if (!server || server.serverErrorCode) { setMeta(key, { tag: undefined }); return true }
        const remote = this.fromRecord(server, db)
        const local = useStore.getState().recs[key]
        if (!remote) return false
        if (!local || Number(remote.f.modifiedAt_ ?? 0) >= Number(local.f.modifiedAt_ ?? 0)) {
          applyRemote([remote], [])
          this.dirty.delete(key)
          return false
        }
        setMeta(key, { tag: remote.tag })
        return true
      }
      case 'NOT_FOUND':
      case 'UNKNOWN_ITEM':
        // Sunucuda yok (silinmiş): yeniden oluştur
        setMeta(key, { tag: undefined })
        return true
      case 'ZONE_NOT_FOUND':
        if (db === 'private') { await this.ensureZone(zoneID.zoneName); return true }
        this.dirty.delete(key)
        return false
      case 'ACCESS_DENIED':
        this.dirty.delete(key)
        report('iCloud kayıt', 'Bu defterde düzenleme iznin yok (salt okunur paylaşım).')
        return false
      case 'THROTTLED':
      case 'TRY_AGAIN_LATER':
      case 'ATOMIC_ERROR':
        return true
      default:
        report('iCloud kayıt', `${failure.serverErrorCode}: ${failure.reason ?? ''}`, { silent: tries < 3 })
        return true
    }
  }

  // MARK: - Kayıt dönüşümü

  private async toFields(rec: Rec, db: Database, zoneID: ZoneID): Promise<Record<string, { value: unknown }> | null> {
    const schema = SCHEMA[rec.entity]
    const fields: Record<string, { value: unknown }> = {}
    for (const [name, type] of Object.entries(schema)) {
      const value = rec.f[name]
      if (type === 'ASSET') {
        const asset = value as AssetRef | null | undefined
        if (asset?.pending && asset.local) {
          const uploaded = await this.uploadAsset(rec, name, asset.local, db, zoneID)
          if (!uploaded) return null
          fields[name] = { value: uploaded }
        } else if (asset == null && rec.tag) {
          fields[name] = { value: null }
        }
        // Değişmemiş varlık: "update" alanı olduğu gibi bırakır
        continue
      }
      if (value === undefined) continue
      if (value === null) { fields[name] = { value: null }; continue }
      switch (type) {
        case 'BOOL': fields[name] = { value: value ? 1 : 0 }; break
        case 'INT64': fields[name] = { value: Math.round(Number(value)) }; break
        case 'DOUBLE': fields[name] = { value: Number(value) }; break
        case 'TIMESTAMP': fields[name] = { value: Math.round(Number(value)) }; break
        default: fields[name] = { value: String(value) }
      }
    }
    if (rec.entity !== 'Notebook') fields.parent = { value: rec.parent ?? null }
    return fields
  }

  private async uploadAsset(rec: Rec, field: string, local: string, db: Database, zoneID: ZoneID): Promise<Record<string, unknown> | null> {
    const base64 = await native.assetRead(local)
    if (!base64) return null
    const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0))
    const url = await ck.uploadURL(db, zoneID, rec.entity, `${rec.entity}.${rec.uuid}`, field)
    const singleFile = await ck.uploadBytes(url, bytes)
    setMeta(recKey(rec), { f: { [field]: { local, remote: singleFile } satisfies AssetRef } })
    return singleFile
  }

  private fromRecord(record: CKRecord, db: Database): Rec | null {
    const entity = record.recordType as Entity
    if (!ENTITIES.includes(entity)) return null
    const dot = record.recordName.indexOf('.')
    if (dot < 0 || record.recordName.slice(0, dot) !== entity) return null
    const uuid = record.recordName.slice(dot + 1)
    const zone = record.zoneID
    if (!zone) return null
    const owner = db === 'private' ? DEFAULT_OWNER : zone.ownerRecordName ?? DEFAULT_OWNER
    const f: Record<string, unknown> = {}
    const schema = SCHEMA[entity]
    for (const [name, raw] of Object.entries(record.fields ?? {})) {
      const type = schema[name]
      if (!type) continue
      const value = raw?.value
      if (value === null || value === undefined) { f[name] = null; continue }
      switch (type) {
        case 'BOOL': f[name] = Number(value) !== 0; break
        case 'INT64': case 'DOUBLE': case 'TIMESTAMP': f[name] = Number(value); break
        case 'ASSET': f[name] = { remote: value as Record<string, unknown> } satisfies AssetRef; break
        default: f[name] = String(value)
      }
    }
    const parent = record.fields?.parent?.value
    return {
      entity, uuid, f, zoneName: zone.zoneName, zoneOwner: owner,
      parent: typeof parent === 'string' ? parent : undefined,
      tag: record.recordChangeTag,
    }
  }

  // MARK: - Çek

  private pollIfDue() {
    if (!ck.isSignedIn) return
    this.tick++
    const active = document.hasFocus()
    const recent = Date.now() - this.lastRemoteChange < 60_000
    // Mac ile aynı: açık ve yakın zamanda değişiklik varsa 2 sn, açıkken 4 sn, arka planda 16 sn
    const every = active ? (recent ? 1 : 2) : 8
    if (this.tick % every === 0) void this.fetchNow()
  }

  async fetchNow() {
    if (!ck.isSignedIn || this.fetching) return
    this.fetching = true
    try {
      for (const db of ['private', 'shared'] as Database[]) await this.fetchDatabase(db)
      useSync.setState({ lastSync: Date.now(), text: `iCloud · son senkron ${new Date().toLocaleTimeString('tr-TR')}` })
    } catch (error) {
      this.handleError('iCloud alma', error)
    } finally {
      this.fetching = false
    }
  }

  private async fetchDatabase(db: Database) {
    let more = true
    let guard = 0
    while (more && guard++ < 50) {
      let res
      try {
        res = await ck.databaseChanges(db, this.state.dbTokens[db])
      } catch (error) {
        // Geçersiz / süresi dolmuş eşitleme belirteci: baştan al
        if (error instanceof CKError && this.state.dbTokens[db] && (error.code === 'BAD_REQUEST' || error.code === 'CHANGE_TOKEN_EXPIRED')) {
          delete this.state.dbTokens[db]
          continue
        }
        throw error
      }
      for (const zone of res.zones ?? []) {
        const owner = db === 'private' ? DEFAULT_OWNER : zone.zoneID.ownerRecordName ?? DEFAULT_OWNER
        const key = zoneKey(zone.zoneID.zoneName, owner)
        if (zone.deleted || zone.purged) { this.zoneGone(key); continue }
        if (!zone.zoneID.zoneName.startsWith('nb-')) continue
        await this.fetchZone(db, zone.zoneID, owner)
      }
      this.state.dbTokens[db] = res.syncToken
      more = !!res.moreComing
    }
    this.persist()
  }

  private zoneGone(key: string) {
    delete this.state.zoneTokens[key]
    if (this.sharesCache[key]) { delete this.sharesCache[key]; setShares({ ...this.sharesCache }) }
    applyRemote([], [], [key])
    this.lastRemoteChange = Date.now()
  }

  private async fetchZone(db: Database, zoneID: ZoneID, owner: string) {
    const key = zoneKey(zoneID.zoneName, owner)
    let more = true
    let guard = 0
    while (more && guard++ < 200) {
      const res = await ck.zoneChanges(db, zoneID, this.state.zoneTokens[key])
      const zone = res.zones?.[0]
      if (!zone) return
      if (zone.serverErrorCode) {
        if (zone.serverErrorCode === 'ZONE_NOT_FOUND' || zone.serverErrorCode === 'ACCESS_DENIED') { this.zoneGone(key); return }
        if (this.state.zoneTokens[key] && zone.serverErrorCode === 'BAD_REQUEST') { delete this.state.zoneTokens[key]; continue }
        throw new CKError(zone.serverErrorCode, zone.reason ?? '', 0)
      }
      const records: Rec[] = []
      const deletions: { entity: Entity; uuid: string }[] = []
      for (const record of zone.records ?? []) {
        record.zoneID = record.zoneID ?? zone.zoneID
        const type = (record.recordType ?? '').toLowerCase()
        if (type.includes('share') || record.recordName === 'cloudkit.zoneshare') {
          if (record.deleted) { delete this.sharesCache[key]; setShares({ ...this.sharesCache }) }
          else this.applyShare(key, record)
          continue
        }
        if (record.deleted) {
          const [entity, ...rest] = record.recordName.split('.')
          if (ENTITIES.includes(entity as Entity)) deletions.push({ entity: entity as Entity, uuid: rest.join('.') })
          continue
        }
        const rec = this.fromRecord(record, db)
        if (rec) records.push(rec)
      }
      // Bekleyen yerel değişikliği olan kaydı ezme (son yazan kazanır, gönderim sürüyor)
      if (records.length || deletions.length) {
        applyRemote(records, deletions.filter((d) => !this.dirty.has(keyOf(d.entity, d.uuid))))
        this.lastRemoteChange = Date.now()
        this.queueDownloads(records)
      }
      this.state.zoneTokens[key] = zone.syncToken
      more = !!zone.moreComing
    }
  }

  private applyShare(key: string, record: CKRecord) {
    const me = useStore.getState().me.id
    const current = record.currentUserParticipant?.userIdentity?.userRecordName
    const name = (p: CKParticipant) => {
      const n = p.userIdentity?.nameComponents
      const full = [n?.givenName, n?.familyName].filter(Boolean).join(' ').trim()
      return full || p.userIdentity?.lookupInfo?.emailAddress || p.userIdentity?.lookupInfo?.phoneNumber || 'Katılımcı'
    }
    const list = [...(record.participants ?? [])]
    if (record.owner && !list.some((p) => p.userIdentity?.userRecordName === record.owner?.userIdentity?.userRecordName)) list.unshift(record.owner)
    const participants = list.map((p) => {
      const id = p.userIdentity?.userRecordName ?? ''
      const isMe = !!id && (id === me || id === current)
      return {
        id, name: name(p), isMe,
        permission: p.permission ?? 'UNKNOWN',
        accepted: p.acceptanceStatus === 'ACCEPTED',
        owner: p.type === 'OWNER',
      }
    })
    const mine = participants.find((p) => p.isMe)
    this.sharesCache[key] = {
      zone: key,
      participants,
      myPermission: record.currentUserParticipant?.permission ?? mine?.permission ?? 'READ_WRITE',
      title: (record.fields?.['cloudkit.title']?.value as string) ?? undefined,
    }
    setShares({ ...this.sharesCache })
  }

  // MARK: - Görselleri indir

  private queueDownloads(records: Rec[]) {
    for (const rec of records) {
      for (const field of ASSET_FIELDS) {
        const asset = rec.f[field] as AssetRef | undefined
        const url = asset?.remote?.downloadURL as string | undefined
        if (!url) continue
        const current = get(rec.entity, rec.uuid)?.f[field] as AssetRef | undefined
        if (current?.local) continue
        const key = `${recKey(rec)}-${field}`
        if (this.downloads.has(key)) continue
        this.downloads.add(key)
        void this.download(rec, field, url).finally(() => this.downloads.delete(key))
      }
    }
  }

  private async download(rec: Rec, field: string, url: string) {
    try {
      const bytes = await ck.download(url, field)
      let binary = ''
      for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
      const name = `${rec.entity}.${rec.uuid}-${field}`
      await native.assetWrite(name, btoa(binary))
      const current = get(rec.entity, rec.uuid)
      const asset = current?.f[field] as AssetRef | undefined
      if (current && asset) setMeta(recKey(current), { f: { [field]: { ...asset, local: name } } })
    } catch (error) {
      report('iCloud görsel', error, { silent: true })
    }
  }

  /** Görünür ama diskte olmayan görseller (ör. adres süresi dolmuş): kaydı yeniden çekip indir */
  async refreshAsset(rec: Rec) {
    const db = dbFor(rec.zoneOwner)
    try {
      const res = await ck.lookup(db, zoneIDFor(rec.zoneName, rec.zoneOwner), [`${rec.entity}.${rec.uuid}`])
      const record = res.records?.[0]
      if (!record || record.serverErrorCode) return
      record.zoneID = record.zoneID ?? zoneIDFor(rec.zoneName, rec.zoneOwner)
      const fresh = this.fromRecord(record, db)
      if (fresh) this.queueDownloads([fresh])
    } catch (error) { report('iCloud görsel', error, { silent: true }) }
  }

  // MARK: - Hatalar

  private handleError(area: string, error: unknown) {
    if (error instanceof CKError) {
      if (error.code === 'NETWORK') { useSync.setState({ text: 'Çevrimdışı — değişiklikler bekletiliyor' }); return }
      if (error.code === 'AUTHENTICATION_REQUIRED' || error.code === 'AUTHENTICATION_FAILED') {
        useSync.setState({ signedIn: false, text: 'iCloud oturumu sona erdi — yeniden giriş yap' })
        return
      }
      if (error.code === 'NO_API_TOKEN') { useSync.setState({ needsAPIToken: true }); return }
      if (error.code === 'BAD_REQUEST' && /schema|production/i.test(error.message)) {
        report(area, 'iCloud şeması henüz yayınlanmadı. CloudKit Console → Schema → Deploy Schema Changes.')
        return
      }
    }
    report(area, error, { silent: error instanceof CKError && ['THROTTLED', 'TRY_AGAIN_LATER', 'INTERNAL_ERROR'].includes(error.code) })
  }

  stop() { clearInterval(this.pollTimer) }
}

export const engine = new Engine()
