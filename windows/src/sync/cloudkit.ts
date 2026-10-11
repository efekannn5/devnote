// CloudKit Web Services istemcisi (Apple'ın resmi REST arayüzü). Mac ve iPhone'un kullandığı aynı
// iCloud kapsayıcısına (iCloud.com.efekan.devnote, production) kullanıcının kendi Apple hesabıyla erişir.
//
// Kimlik: API anahtarı (uygulamaya ait) + ckWebAuthToken (kullanıcının oturumu). Oturum belirteci her
// yanıtta yenilenir (X-Apple-CloudKit-Web-Auth-Token); istekler sırayla gönderilir ve en yeni belirteç saklanır.

import { native } from '../lib/native'

export const CONTAINER = 'iCloud.com.efekan.devnote'
export const ENVIRONMENT = 'production'
const BASE = `https://api.apple-cloudkit.com/database/1/${CONTAINER}/${ENVIRONMENT}`

export type Database = 'private' | 'shared' | 'public'

export interface ZoneID { zoneName: string; ownerRecordName?: string }

export interface CKField { value: unknown; type?: string }

export interface CKRecord {
  recordName: string
  recordType?: string
  recordChangeTag?: string
  fields?: Record<string, CKField>
  deleted?: boolean
  zoneID?: ZoneID
  created?: { timestamp: number; userRecordName?: string }
  modified?: { timestamp: number; userRecordName?: string }
  // Paylaşım kaydı
  participants?: CKParticipant[]
  owner?: CKParticipant
  currentUserParticipant?: CKParticipant
  publicPermission?: string
  // Kayıt bazında hata
  serverErrorCode?: string
  reason?: string
  serverRecord?: CKRecord
  retryAfter?: number
}

export interface CKParticipant {
  userIdentity?: {
    userRecordName?: string
    nameComponents?: { givenName?: string; familyName?: string; nickname?: string }
    lookupInfo?: { emailAddress?: string; phoneNumber?: string }
  }
  permission?: string
  type?: string
  acceptanceStatus?: string
}

export class CKError extends Error {
  code: string
  status: number
  body?: Record<string, unknown>
  constructor(code: string, message: string, status: number, body?: Record<string, unknown>) {
    super(message)
    this.code = code
    this.status = status
    this.body = body
  }
  get redirectURL(): string | undefined { return this.body?.redirectURL as string | undefined }
  get retryAfter(): number | undefined { return this.body?.retryAfter as number | undefined }
}

const TOKEN_KEY = 'ckWebAuthToken'
const API_KEY = 'ckAPIToken'

/**
 * Uygulamanın CloudKit API anahtarı (CloudKit Console → API Access → API Tokens).
 * Derlemeye gömülebilir; boşsa kullanıcı ilk açılışta yapıştırır (Windows Kimlik Bilgisi Yöneticisi'nde saklanır).
 */
export const EMBEDDED_API_TOKEN = (import.meta.env.VITE_CK_API_TOKEN as string | undefined) ?? ''

class Client {
  private apiToken = EMBEDDED_API_TOKEN
  private webToken: string | null = null
  private queue: Promise<unknown> = Promise.resolve()
  onSignedOut: (() => void) | null = null

  async load() {
    if (!this.apiToken) this.apiToken = (await native.secretGet(API_KEY)) ?? ''
    this.webToken = await native.secretGet(TOKEN_KEY)
  }

  get hasAPIToken() { return !!this.apiToken }
  get isSignedIn() { return !!this.webToken }

  async setAPIToken(token: string) {
    this.apiToken = token.trim()
    await native.secretSet(API_KEY, this.apiToken)
  }

  async setWebToken(token: string | null) {
    this.webToken = token
    if (token) await native.secretSet(TOKEN_KEY, token)
    else await native.secretDelete(TOKEN_KEY)
  }

  private url(db: Database, op: string, auth = true): string {
    let url = `${BASE}/${db}/${op}?ckAPIToken=${encodeURIComponent(this.apiToken)}`
    if (auth && this.webToken) url += `&ckWebAuthToken=${encodeURIComponent(this.webToken)}`
    return url
  }

  /** İstekleri sıraya koy: dönen yeni belirteç bir sonrakinde kullanılsın */
  request<T>(db: Database, op: string, body?: unknown, opts: { auth?: boolean; method?: 'GET' | 'POST' } = {}): Promise<T> {
    const run = () => this.send<T>(db, op, body, opts)
    const next = this.queue.then(run, run)
    this.queue = next.catch(() => undefined)
    return next
  }

  private async send<T>(db: Database, op: string, body: unknown, opts: { auth?: boolean; method?: 'GET' | 'POST' }, attempt = 0): Promise<T> {
    if (!this.apiToken) throw new CKError('NO_API_TOKEN', 'CloudKit API anahtarı yok', 0)
    const method = opts.method ?? (body === undefined ? 'GET' : 'POST')
    let response: Response
    try {
      response = await native.fetch(this.url(db, op, opts.auth !== false), {
        method,
        headers: method === 'POST' ? { 'Content-Type': 'application/json' } : undefined,
        body: method === 'POST' ? JSON.stringify(body ?? {}) : undefined,
      })
    } catch (error) {
      throw new CKError('NETWORK', `Ağ hatası: ${String(error)}`, 0)
    }
    const rotated = response.headers.get('X-Apple-CloudKit-Web-Auth-Token')
    if (rotated && rotated !== this.webToken && opts.auth !== false) await this.setWebToken(rotated)

    const text = await response.text()
    let json: Record<string, unknown> = {}
    try { json = text ? JSON.parse(text) : {} } catch { /* düz metin hata */ }
    if (typeof json.ckWebAuthToken === 'string' && opts.auth !== false) await this.setWebToken(json.ckWebAuthToken)

    if (response.ok) return json as T
    const code = (json.serverErrorCode as string) ?? `HTTP_${response.status}`
    const error = new CKError(code, (json.reason as string) ?? text ?? response.statusText, response.status, json)
    if (code === 'AUTHENTICATION_REQUIRED' || code === 'AUTHENTICATION_FAILED' || response.status === 421) {
      if (opts.auth !== false && this.webToken) {
        await this.setWebToken(null)
        this.onSignedOut?.()
      }
      throw error
    }
    // Geçici hatalar: bekle ve tekrar dene
    if ((code === 'THROTTLED' || code === 'TRY_AGAIN_LATER' || code === 'INTERNAL_ERROR' || response.status >= 500) && attempt < 3) {
      const wait = (error.retryAfter ?? 2 ** attempt) * 1000 + Math.random() * 300
      await new Promise((r) => setTimeout(r, wait))
      return this.send<T>(db, op, body, opts, attempt + 1)
    }
    throw error
  }

  // MARK: - Giriş

  /** Oturumsuz istek → 421 ile Apple giriş sayfasının adresi */
  async signInURL(): Promise<string> {
    try {
      await this.request('public', 'users/current', undefined, { auth: false })
    } catch (error) {
      if (error instanceof CKError && error.redirectURL) return error.redirectURL
      throw error
    }
    throw new CKError('NO_REDIRECT', 'Apple giriş adresi alınamadı', 0)
  }

  async currentUser(): Promise<{ userRecordName: string; firstName?: string; lastName?: string }> {
    return this.request('public', 'users/current')
  }

  async caller(): Promise<{ users?: { userRecordName: string; nameComponents?: { givenName?: string; familyName?: string } }[] }> {
    return this.request('public', 'users/caller')
  }

  async signOut() { await this.setWebToken(null) }

  // MARK: - Değişiklikler

  async databaseChanges(db: Database, syncToken?: string): Promise<{ zones: ({ zoneID: ZoneID; deleted?: boolean; purged?: boolean } & Partial<CKRecord>)[]; syncToken: string; moreComing?: boolean }> {
    return this.request(db, 'changes/database', { syncToken, resultsLimit: 200 })
  }

  async zoneChanges(db: Database, zoneID: ZoneID, syncToken?: string): Promise<{ zones: { zoneID: ZoneID; syncToken: string; moreComing?: boolean; records?: CKRecord[]; serverErrorCode?: string; reason?: string }[] }> {
    return this.request(db, 'changes/zone', { zones: [{ zoneID, syncToken, resultsLimit: 200 }] })
  }

  async modifyRecords(db: Database, zoneID: ZoneID, operations: { operationType: string; record: Partial<CKRecord> }[]): Promise<{ records: CKRecord[] }> {
    return this.request(db, 'records/modify', { zoneID, atomic: false, operations })
  }

  async lookup(db: Database, zoneID: ZoneID, recordNames: string[]): Promise<{ records: CKRecord[] }> {
    return this.request(db, 'records/lookup', { zoneID, records: recordNames.map((recordName) => ({ recordName })) })
  }

  async modifyZones(db: Database, operations: { operationType: 'create' | 'delete'; zone: { zoneID: ZoneID } }[]): Promise<{ zones: ({ zoneID: ZoneID } & Partial<CKRecord>)[] }> {
    return this.request(db, 'zones/modify', { operations })
  }

  async uploadURL(db: Database, zoneID: ZoneID, recordType: string, recordName: string, fieldName: string): Promise<string> {
    const res = await this.request<{ tokens: { url: string }[] }>(db, 'assets/upload', { zoneID, tokens: [{ recordType, recordName, fieldName }] })
    const url = res.tokens?.[0]?.url
    if (!url) throw new CKError('NO_UPLOAD_URL', 'Yükleme adresi alınamadı', 0)
    return url
  }

  /** Ön imzalı adrese ham baytları gönder → kayıtta kullanılacak varlık sözlüğü */
  async uploadBytes(url: string, bytes: Uint8Array): Promise<Record<string, unknown>> {
    const response = await native.fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: bytes as unknown as BodyInit })
    const json = await response.json() as { singleFile?: Record<string, unknown> }
    if (!response.ok || !json.singleFile) throw new CKError('UPLOAD_FAILED', 'Görsel yüklenemedi', response.status)
    return json.singleFile
  }

  async download(downloadURL: string, name = 'file'): Promise<Uint8Array> {
    const response = await native.fetch(downloadURL.replace('${f}', encodeURIComponent(name)))
    if (!response.ok) throw new CKError('DOWNLOAD_FAILED', `İndirilemedi (${response.status})`, response.status)
    return new Uint8Array(await response.arrayBuffer())
  }
}

export const ck = new Client()
