import Foundation
import CoreData
import CloudKit
import Combine

/// iCloud senkronu — CKSyncEngine.
///
/// - Her kayıttan sonra değişiklikler *hemen* gönderilir (sendChanges), push gelince ve uygulama
///   açıkken birkaç saniyede bir değişiklikler çekilir (fetchChanges). NSPersistentCloudKitContainer'ın
///   kendi zamanlamasına bağlı kalınmaz.
/// - Her defter kendi CloudKit bölgesindedir (zone). Paylaşım bölge düzeyindedir (CKShare(recordZoneID:)):
///   defter paylaşılınca sayfaları ve blokları da otomatik paylaşılır.
/// - Kayıt adı "<Entity>.<uuid>"; çakışmada `modifiedAt_` daha yeni olan kazanır.
final class CloudSync: ObservableObject, CKSyncEngineDelegate, @unchecked Sendable {
    static let shared = CloudSync()
    /// Buluttan uygulanan kayıtları yeniden göndermemek için transactionAuthor.
    static let author = "cloudkit"

    @Published private(set) var status = Persistence.cloudEnabled ? "iCloud'a bağlanıyor…" : "Yerel depolama"
    /// Bölge anahtarı ("sahip/bölge") → paylaşım. Arayüz senkron erişebilsin diye önbellekte.
    @Published private(set) var shares: [String: CKShare] = [:]

    let ckContainer = CKContainer(identifier: Persistence.cloudContainerID)
    private var privateEngine: CKSyncEngine?
    private var sharedEngine: CKSyncEngine?
    private var started = false
    private var saveObserver: NSObjectProtocol?
    private var sendTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var lastRemoteChange = Date.distantPast

    private static let entities = EntityGraph.entities
    // İkili veriler (görsel, çizim) her zaman CKAsset olarak gider: kayıt 1 MB sınırına takılmaz ve
    // CloudKit alan türü sabit kalır (ilk kayıtta bayt, sonra dosya olursa sunucu reddeder).
    /// CloudKit'e gönderilmeyen (bölgeden türetilen ya da yerel) alanlar
    private static let localOnly: Set<String> = ["uuid_", "zoneName_", "zoneOwner_", "ckSystemFields_", "parentUUID_"]

    // MARK: - Başlatma

    @MainActor
    func start() {
        guard !started else { return }
        Self.cleanAssetCache()
        started = true
        resetIfEnvironmentChanged()
        loadCachedShares()
        privateEngine = CKSyncEngine(configuration(for: ckContainer.privateCloudDatabase, key: "private"))
        sharedEngine = CKSyncEngine(configuration(for: ckContainer.sharedCloudDatabase, key: "shared"))

        let context = Persistence.shared.context
        saveObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextWillSave, object: context, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureLocalChanges(in: context) }
        }
        enqueueUnsyncedObjects()
        setActive(true)
        setStatus("iCloud senkronu açık")
    }

    /// Entitlement'taki `icloud-container-environment` ile aynı olmalı. Development ve Production ayrı
    /// veritabanlarıdır; tüm sürümler (Xcode, TestFlight) Production kullanır ki herkes aynı veriyi görsün.
    static let environment = "production"

    /// Ortam değiştiyse (ör. Development'tan Production'a geçiş) eski senkron durumu geçersizdir:
    /// durumu sil, kayıt meta verisini temizle; açılışta her şey yeni ortama yeniden gönderilir.
    @MainActor
    private func resetIfEnvironmentChanged() {
        let key = "ckEnvironment"
        guard UserDefaults.standard.string(forKey: key) != Self.environment else { return }
        for name in ["engine-private.json", "engine-shared.json", "shares.plist"] {
            try? FileManager.default.removeItem(at: Self.directory.appending(path: name))
        }
        var count = 0
        asRemote { context in
            for entity in Self.entities {
                let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                request.predicate = NSPredicate(format: "ckSystemFields_ != nil")
                for object in (try? context.fetch(request)) ?? [] {
                    object.setValue(nil, forKey: "ckSystemFields_")
                    count += 1
                }
            }
        }
        UserDefaults.standard.set(Self.environment, forKey: key)
        print("☁️ iCloud ortamı: \(Self.environment) — senkron durumu sıfırlandı, \(count) kayıt yeniden gönderilecek")
    }

    private func configuration(for database: CKDatabase, key: String) -> CKSyncEngine.Configuration {
        var config = CKSyncEngine.Configuration(database: database, stateSerialization: loadState(key), delegate: self)
        config.automaticallySync = true
        return config
    }

    func setStatus(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }

    private var isActive = true
    private var pollTick = 0

    /// Uygulama açıkken sık sık değişiklik sor (push gecikse bile birkaç saniyede gelsin).
    /// Aktif: son bir dakikada değişiklik olduysa 2 sn, yoksa 4 sn. Mac'te arka planda: 20 sn.
    @MainActor
    func setActive(_ active: Bool) {
        isActive = active
        guard started else { return }
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.pollIfDue()
            }
        }
        #if os(iOS)
        if !active { pollTimer?.invalidate(); pollTimer = nil; return }   // iOS arka planda push'a güven
        #endif
        if active {
            Task.detached { [weak self] in await self?.fetchLogged() }
            Task { await refreshShares() }
        }
    }

    private func pollIfDue() {
        pollTick += 1
        let recent = Date.now.timeIntervalSince(lastRemoteChange) < 60
        let every = isActive ? (recent ? 1 : 2) : 10
        guard pollTick % every == 0 else { return }
        Task.detached { [weak self] in await self?.fetchLogged() }
    }

    private func fetchLogged() async {
        do { try await fetchNow() } catch { Self.report(error, "iCloud alma") }
    }

    /// Katılımcı listeleri güncel olsun (paylaşım ekranında kişi eklenip çıkarılmış olabilir).
    @MainActor
    private func refreshShares() async {
        let request = Notebook.fetchAll()
        for notebook in (try? Persistence.shared.context.fetch(request)) ?? [] where Persistence.shared.isShared(notebook) {
            await refreshShare(for: notebook)
        }
    }

    func fetchNow() async throws {
        try await privateEngine?.fetchChanges()
        try await sharedEngine?.fetchChanges()
    }

    private func engine(forOwner owner: String?) -> CKSyncEngine? {
        (owner ?? CKCurrentUserDefaultName) == CKCurrentUserDefaultName ? privateEngine : sharedEngine
    }

    // MARK: - Kimlikler

    static func zoneID(name: String?, owner: String?) -> CKRecordZone.ID? {
        guard let name else { return nil }
        return CKRecordZone.ID(zoneName: name, ownerName: owner ?? CKCurrentUserDefaultName)
    }

    static func recordID(for object: NSManagedObject) -> CKRecord.ID? {
        guard let uuid = object.value(forKey: "uuid_") as? UUID, let entity = object.entity.name,
              let zone = zoneID(name: object.value(forKey: "zoneName_") as? String,
                                owner: object.value(forKey: "zoneOwner_") as? String) else { return nil }
        return CKRecord.ID(recordName: "\(entity).\(uuid.uuidString)", zoneID: zone)
    }

    private static func parse(_ recordName: String) -> (entity: String, uuid: UUID)? {
        let parts = recordName.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, entities.contains(String(parts[0])), let uuid = UUID(uuidString: String(parts[1])) else { return nil }
        return (String(parts[0]), uuid)
    }

    private static func zoneKey(_ zone: CKRecordZone.ID) -> String { "\(zone.ownerName)/\(zone.zoneName)" }

    // MARK: - Yerel değişiklikleri kuyruğa al

    @MainActor
    private func captureLocalChanges(in context: NSManagedObjectContext) {
        // Buluttan / yakın cihazdan gelen kayıtları yeniden gönderme
        guard context.transactionAuthor == nil else { return }
        var deletedZones = Set<String>()

        for object in context.deletedObjects {
            guard let id = Self.recordID(for: object) else { continue }
            if object is Notebook {
                // Kendi defterim → bölgeyi sil; paylaşılan defter → bölgeyi silmek paylaşımdan ayrılmaktır
                engine(forOwner: id.zoneID.ownerName)?.state.add(pendingDatabaseChanges: [.deleteZone(id.zoneID)])
                deletedZones.insert(Self.zoneKey(id.zoneID))
                removeShare(for: id.zoneID)
            }
        }
        for object in context.deletedObjects where !(object is Notebook) {
            guard let id = Self.recordID(for: object), !deletedZones.contains(Self.zoneKey(id.zoneID)) else { continue }
            engine(forOwner: id.zoneID.ownerName)?.state.add(pendingRecordZoneChanges: [.deleteRecord(id)])
        }

        for object in context.insertedObjects.union(context.updatedObjects) where object.hasPersistentChangedValues {
            let changed = object.changedValues().keys
            // Yalnızca senkron meta verisi değiştiyse gönderme
            guard !Set(changed).isSubset(of: ["ckSystemFields_"]) else { continue }
            guard let id = Self.recordID(for: object), let engine = engine(forOwner: id.zoneID.ownerName) else { continue }

            // Bölge değiştiyse (sayfa başka deftere taşındı) eski kaydı sil
            if !object.isInserted, changed.contains("zoneName_") || changed.contains("zoneOwner_") {
                let old = object.committedValues(forKeys: ["zoneName_", "zoneOwner_"])
                if let oldZone = Self.zoneID(name: old["zoneName_"] as? String, owner: old["zoneOwner_"] as? String) {
                    let oldID = CKRecord.ID(recordName: id.recordName, zoneID: oldZone)
                    self.engine(forOwner: oldZone.ownerName)?.state.add(pendingRecordZoneChanges: [.deleteRecord(oldID)])
                }
                object.setValue(nil, forKey: "ckSystemFields_")
            }
            if object.isInserted, object is Notebook, id.zoneID.ownerName == CKCurrentUserDefaultName {
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: id.zoneID))])
            }
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
        }
        scheduleSend()
    }

    /// Hiç gönderilmemiş nesneleri (iCloud kapalıyken / başlamadan önce oluşanlar) kuyruğa al.
    @MainActor
    private func enqueueUnsyncedObjects() {
        let context = Persistence.shared.context
        var count = 0
        for entity in Self.entities {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.predicate = NSPredicate(format: "ckSystemFields_ == nil")
            for object in (try? context.fetch(request)) ?? [] {
                guard let id = Self.recordID(for: object), let engine = engine(forOwner: id.zoneID.ownerName) else { continue }
                if object is Notebook, id.zoneID.ownerName == CKCurrentUserDefaultName {
                    engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: id.zoneID))])
                }
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                count += 1
            }
        }
        if count > 0 { print("☁️ \(count) gönderilmemiş nesne kuyruğa alındı"); scheduleSend() }
    }

    /// Ardışık kayıtları kısa bir pencerede toplayıp hemen gönder.
    private func scheduleSend() {
        sendTask?.cancel()
        // Detached: delege çağrısının içinden CKSyncEngine'e geri dönmek yasak
        sendTask = Task.detached { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            for engine in [privateEngine, sharedEngine].compactMap({ $0 })
            where !engine.state.pendingRecordZoneChanges.isEmpty || !engine.state.pendingDatabaseChanges.isEmpty {
                do { try await engine.sendChanges() } catch { Self.report(error, "iCloud gönderme") }
            }
        }
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            saveState(update.stateSerialization, key: syncEngine === sharedEngine ? "shared" : "private")

        case .accountChange(let change):
            print("☁️ hesap değişti: \(change.changeType)")

        case .fetchedDatabaseChanges(let changes):
            let deleted = changes.deletions.map(\.zoneID)
            guard !deleted.isEmpty else { return }
            await MainActor.run { self.applyZoneDeletions(deleted) }

        case .fetchedRecordZoneChanges(let changes):
            let records = changes.modifications.map(\.record)
            let deletions = changes.deletions.map { ($0.recordID, $0.recordType) }
            guard !records.isEmpty || !deletions.isEmpty else { return }
            await MainActor.run { self.applyRemote(records: records, deletions: deletions) }

        case .sentRecordZoneChanges(let sent):
            await MainActor.run { self.handleSent(sent, engine: syncEngine) }

        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                Self.report(failure.error, "iCloud defter")
            }

        case .didFetchChanges:
            setStatus("iCloud · son senkron \(Date.now.formatted(date: .omitted, time: .standard))")

        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await MainActor.run {
                if let record = self.makeRecord(for: recordID) { return record }
                // Nesne artık yok → kuyruktan çıkar
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
        }
    }

    // MARK: - Nesne → CKRecord

    @MainActor
    private func makeRecord(for id: CKRecord.ID) -> CKRecord? {
        guard let (entity, uuid) = Self.parse(id.recordName),
              let object = find(entity, uuid), Self.recordID(for: object) == id else { return nil }

        var record = CKRecord(recordType: entity, recordID: id)
        if let data = object.value(forKey: "ckSystemFields_") as? Data,
           let coder = try? NSKeyedUnarchiver(forReadingFrom: data) {
            coder.requiresSecureCoding = true
            if let cached = CKRecord(coder: coder), cached.recordID == id { record = cached }
            coder.finishDecoding()
        }
        for (name, desc) in object.entity.attributesByName where !Self.localOnly.contains(name) {
            let value = object.value(forKey: name)
            record[name] = switch (desc.attributeType, value) {
            case (_, nil): nil
            case (.UUIDAttributeType, let id as UUID): id.uuidString as CKRecordValue
            case (.binaryDataAttributeType, let data as Data):
                Self.asset(data, name: "\(id.recordName)-\(name)")
            default: value as? CKRecordValue
            }
        }
        let parent = EntityGraph.parentObject(of: object)
        record["parent"] = (parent?.value(forKey: "uuid_") as? UUID)?.uuidString as CKRecordValue?
        return record
    }

    private static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    // MARK: - Uzak değişiklikleri uygula

    @MainActor
    private func applyRemote(records: [CKRecord], deletions: [(CKRecord.ID, CKRecord.RecordType)]) {
        asRemote { context in applyRemote(records: records, deletions: deletions, in: context) }
        TaskNotifier.shared.scheduleRefresh()
    }

    @MainActor
    private func applyRemote(records: [CKRecord], deletions: [(CKRecord.ID, CKRecord.RecordType)],
                             in context: NSManagedObjectContext) {
        let order = EntityGraph.order
        var touched: [NSManagedObject] = []

        for record in records.sorted(by: { order[$0.recordType] ?? 9 < order[$1.recordType] ?? 9 }) {
            if let share = record as? CKShare {
                setShare(share, for: record.recordID.zoneID)
                continue
            }
            guard let (entityName, uuid) = Self.parse(record.recordID.recordName),
                  let entity = DataModel.shared.entitiesByName[entityName] else { continue }

            let existing = find(entityName, uuid)
            let object = existing ?? {
                let created = NSManagedObject(entity: entity, insertInto: context)
                created.setValue(uuid, forKey: "uuid_")
                return created
            }()
            object.setValue(Self.systemFields(of: record), forKey: "ckSystemFields_")
            object.setValue(record.recordID.zoneID.zoneName, forKey: "zoneName_")
            object.setValue(record.recordID.zoneID.ownerName, forKey: "zoneOwner_")

            // Son yazan kazanır: yerel kopya daha yeniyse alanları ezme
            if let existing, let local = existing.value(forKey: "modifiedAt_") as? Date,
               let remote = record["modifiedAt_"] as? Date, local > remote { continue }

            for (name, desc) in entity.attributesByName where !Self.localOnly.contains(name) {
                let raw = record[name]
                let value: Any? = switch (desc.attributeType, raw) {
                case (.UUIDAttributeType, let s as String): UUID(uuidString: s)
                case (.binaryDataAttributeType, let asset as CKAsset): asset.fileURL.flatMap { try? Data(contentsOf: $0) }
                default: raw
                }
                let current = object.value(forKey: name)
                if (current as AnyObject?)?.isEqual(value) != true && !(current == nil && value == nil) {
                    object.setValue(value, forKey: name)
                }
            }
            if entityName != "Notebook" {
                object.setValue((record["parent"] as? String).flatMap(UUID.init(uuidString:)), forKey: "parentUUID_")
            }
            touched.append(object)
        }

        linkOrphans()

        for (id, type) in deletions {
            if type == CKRecord.SystemType.share { removeShare(for: id.zoneID); continue }
            guard let (entity, uuid) = Self.parse(id.recordName), let object = find(entity, uuid),
                  Self.recordID(for: object) == id else { continue }
            context.delete(object)
        }

        if context.hasChanges {
            lastRemoteChange = .now
            print("☁️ \(Date.now.formatted(date: .omitted, time: .standard)) buluttan: \(touched.count) değişiklik, \(deletions.count) silme")
        }
    }

    /// Ebeveyni sonra gelen sayfa/blokları bağla.
    @MainActor
    private func linkOrphans() {
        let context = Persistence.shared.context
        for (entity, link) in EntityGraph.parent {
            let (parentEntity, key) = link
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.predicate = NSPredicate(format: "parentUUID_ != nil")
            for object in (try? context.fetch(request)) ?? [] {
                guard let parentID = object.value(forKey: "parentUUID_") as? UUID else { continue }
                let current = (object.value(forKey: key) as? NSManagedObject)?.value(forKey: "uuid_") as? UUID
                guard current != parentID, let parent = find(parentEntity, parentID) else { continue }
                object.setValue(parent, forKey: key)
            }
        }
    }

    @MainActor
    private func applyZoneDeletions(_ zones: [CKRecordZone.ID]) {
        asRemote { context in
            for zone in zones {
                removeShare(for: zone)
                let request = Notebook.fetchAll()
                request.predicate = NSPredicate(format: "zoneName_ == %@ AND zoneOwner_ == %@", zone.zoneName, zone.ownerName)
                for notebook in (try? context.fetch(request)) ?? [] { context.delete(notebook) }
            }
        }
    }

    @MainActor
    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) {
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        var zonesToCreate: [CKRecordZone] = []
        asRemote { context in handleSent(sent, retry: &retry, zonesToCreate: &zonesToCreate, in: context) }
        if !zonesToCreate.isEmpty { engine.state.add(pendingDatabaseChanges: zonesToCreate.map { .saveZone($0) }) }
        if !retry.isEmpty { engine.state.add(pendingRecordZoneChanges: retry); scheduleSend() }
        TaskNotifier.shared.scheduleRefresh()
    }

    @MainActor
    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, retry: inout [CKSyncEngine.PendingRecordZoneChange],
                            zonesToCreate: inout [CKRecordZone], in context: NSManagedObjectContext) {
        for record in sent.savedRecords {
            guard let (entity, uuid) = Self.parse(record.recordID.recordName), let object = find(entity, uuid) else { continue }
            object.setValue(Self.systemFields(of: record), forKey: "ckSystemFields_")
        }
        if !sent.savedRecords.isEmpty || !sent.deletedRecordIDs.isEmpty {
            print("☁️ \(Date.now.formatted(date: .omitted, time: .standard)) buluta gönderildi: \(sent.savedRecords.count) kayıt, \(sent.deletedRecordIDs.count) silme, \(sent.failedRecordSaves.count) hata")
        }

        for failure in sent.failedRecordSaves {
            let id = failure.record.recordID
            let object = Self.parse(id.recordName).flatMap { find($0.entity, $0.uuid) }
            switch failure.error.code {
            case .serverRecordChanged:
                // Sunucuda daha yeni sürüm var: sunucunun sistem alanlarını al; değerleri yeniyse
                // uygula, değilse bizimkini yeniden gönder.
                if let server = failure.error.serverRecord {
                    applyRemote(records: [server], deletions: [], in: context)
                    let local = object?.value(forKey: "modifiedAt_") as? Date ?? .distantPast
                    let remote = server["modifiedAt_"] as? Date ?? .distantPast
                    if local > remote { retry.append(.saveRecord(id)) }
                }
            case .zoneNotFound, .userDeletedZone:
                if id.zoneID.ownerName == CKCurrentUserDefaultName {
                    zonesToCreate.append(CKRecordZone(zoneID: id.zoneID))
                    retry.append(.saveRecord(id))
                }
            case .unknownItem:
                object?.setValue(nil, forKey: "ckSystemFields_")
                retry.append(.saveRecord(id))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .notAuthenticated, .operationCancelled, .requestRateLimited:
                break   // CKSyncEngine kendisi yeniden dener
            default:
                Self.report(failure.error, "iCloud kayıt")
            }
        }
    }

    /// Önce bekleyen kullanıcı değişikliklerini (gönderilecek şekilde) kaydet, sonra `body`'yi
    /// "buluttan" etiketiyle çalıştırıp kaydet. İç içe çağrılarda etiket korunur.
    @MainActor
    private func asRemote(_ body: (NSManagedObjectContext) -> Void) {
        let context = Persistence.shared.context
        let previous = context.transactionAuthor
        if previous == nil { Persistence.shared.save() }
        context.transactionAuthor = Self.author
        body(context)
        if context.hasChanges { try? context.save() }
        context.transactionAuthor = previous
    }

    @MainActor
    private func find(_ entity: String, _ uuid: UUID) -> NSManagedObject? {
        guard DataModel.shared.entitiesByName[entity] != nil else { return nil }   // bilinmeyen tür (daha yeni sürüm)
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "uuid_ == %@", uuid as NSUUID)
        request.fetchLimit = 1
        return try? Persistence.shared.context.fetch(request).first
    }

    // MARK: - Paylaşım

    func share(forZone name: String?, owner: String?) -> CKShare? {
        guard let zone = Self.zoneID(name: name, owner: owner) else { return nil }
        return shares[Self.zoneKey(zone)]
    }

    /// Defterin bölgesi için paylaşım oluşturur ya da var olanı döndürür.
    @MainActor
    func makeShare(for notebook: Notebook) async throws -> CKShare {
        guard let zoneID = Self.zoneID(name: notebook.zoneName_, owner: notebook.zoneOwner_) else {
            throw CKError(.invalidArguments)
        }
        if let existing = shares[Self.zoneKey(zoneID)] { return existing }
        Persistence.shared.save()
        let database = ckContainer.privateCloudDatabase
        // Bölge ve kayıtlar sunucuda olmalı
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        try? await privateEngine?.sendChanges()

        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = notebook.name as CKRecordValue
        share.publicPermission = .none
        let result = try await database.modifyRecords(saving: [share], deleting: [])
        guard let saved = try result.saveResults[share.recordID]?.get() as? CKShare else {
            throw CKError(.internalError)
        }
        setShare(saved, for: zoneID)
        return saved
    }

    /// Sunucudaki güncel paylaşımı al (katılımcı eklendi/çıkarıldıysa).
    @MainActor
    func refreshShare(for notebook: Notebook) async {
        guard let zoneID = Self.zoneID(name: notebook.zoneName_, owner: notebook.zoneOwner_) else { return }
        let database = zoneID.ownerName == CKCurrentUserDefaultName ? ckContainer.privateCloudDatabase : ckContainer.sharedCloudDatabase
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        if let share = try? await database.record(for: id) as? CKShare { setShare(share, for: zoneID) }
    }

    func accept(_ metadata: CKShare.Metadata) async {
        do {
            _ = try await ckContainer.accept(metadata)
            try await sharedEngine?.fetchChanges()
            print("☁️ paylaşım kabul edildi")
        } catch {
            setStatus("Davet kabul edilemedi: \(error.localizedDescription)")
        }
    }

    private func setShare(_ share: CKShare, for zone: CKRecordZone.ID) {
        DispatchQueue.main.async {
            self.shares[Self.zoneKey(zone)] = share
            self.persistShares()
        }
    }

    private func removeShare(for zone: CKRecordZone.ID) {
        DispatchQueue.main.async {
            self.shares[Self.zoneKey(zone)] = nil
            self.persistShares()
        }
    }

    // MARK: - Kalıcılık

    private static let directory: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "Sync", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func loadState(_ key: String) -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: Self.directory.appending(path: "engine-\(key).json")) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveState(_ state: CKSyncEngine.State.Serialization, key: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.directory.appending(path: "engine-\(key).json"), options: .atomic)
    }

    private func persistShares() {
        let archived = shares.compactMapValues { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        try? PropertyListEncoder().encode(archived).write(to: Self.directory.appending(path: "shares.plist"), options: .atomic)
    }

    private func loadCachedShares() {
        guard let data = try? Data(contentsOf: Self.directory.appending(path: "shares.plist")),
              let archived = try? PropertyListDecoder().decode([String: Data].self, from: data) else { return }
        shares = archived.compactMapValues { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKShare.self, from: $0) }
    }
}

extension CloudSync {
    /// Ağ yok / iCloud meşgul gibi kendiliğinden düzelen hatalar yalnızca günlüğe yazılır.
    nonisolated static func report(_ error: Error, _ area: String) {
        // notAuthenticated: iCloud'a giriş yok — durum çubuğunda zaten yazıyor, her denemede uyarı göstermeyelim
        let transient: Set<CKError.Code> = [.networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                                            .operationCancelled, .requestRateLimited, .notAuthenticated,
                                            .accountTemporarilyUnavailable,
                                            .partialFailure]   // kayıt bazındaki hatalar ayrıca raporlanıyor
        let code = (error as? CKError)?.code
        // Şema Production'a yayınlanmamış: her kayıt için ayrı uyarı yerine tek, ne yapılacağını söyleyen uyarı
        if ErrorReporter.describe(error).contains("production schema") {
            ErrorReporter.shared.report(error, area: area, silent: true)
            if schemaWarning.claim() {
                ErrorReporter.shared.report(message: "iCloud şeması henüz yayınlanmadı; notlar buluta gidemiyor. "
                    + "CloudKit Console → iCloud.com.efekan.devnote → Schema → Deploy Schema Changes. "
                    + "Bu sırada aynı Wi‑Fi'deki cihazlar yine eşitlenir.", area: "iCloud şema")
            }
            return
        }
        ErrorReporter.shared.report(error, area: area, silent: code.map(transient.contains) ?? false)
    }

    /// Şema uyarısı oturumda bir kez
    private static let schemaWarning = Once()
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }
}

extension CloudSync {
    /// Büyük ikili veriyi CloudKit'e dosya olarak gönder. Dosyalar önbellekte kalır; 2 günden eskiler silinir.
    fileprivate static func asset(_ data: Data, name: String) -> CKAsset? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "CKAssets", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name.replacingOccurrences(of: "/", with: "_"))
        do {
            try data.write(to: url, options: .atomic)
            return CKAsset(fileURL: url)
        } catch {
            ErrorReporter.shared.report(error, area: "iCloud dosya", silent: true)
            return nil
        }
    }

    static func cleanAssetCache() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "CKAssets")
        let old = Date.now.addingTimeInterval(-2 * 86_400)
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
            if date < old { try? FileManager.default.removeItem(at: url) }
        }
    }
}
