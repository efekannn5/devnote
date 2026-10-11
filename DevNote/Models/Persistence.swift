import Foundation
import CoreData
import CloudKit
import Combine

/// Yerel Core Data yığını. iCloud senkronu `CloudSync` (CKSyncEngine), yakın cihazlar arası
/// anlık senkron `PeerSync` tarafından yapılır; ikisi de bu bağlamdaki kayıtları dinler.
final class Persistence: ObservableObject {
    static let shared = Persistence()
    static let cloudContainerID = "iCloud.com.efekan.devnote"

    #if ICLOUD_SYNC
    static let cloudEnabled = true
    #else
    static let cloudEnabled = false
    #endif

    let container: NSPersistentContainer

    /// Bu cihazdaki iCloud kullanıcısı. `id`, CloudKit userRecordID.recordName'dir.
    @Published private(set) var me = Person(id: "local-user", name: "Ben", isMe: true)
    @Published private(set) var lastError: String?

    var context: NSManagedObjectContext { container.viewContext }

    private var autosave: AnyCancellable?

    private init() {
        container = NSPersistentContainer(name: "DevNote", managedObjectModel: DataModel.shared)
        let url = NSPersistentContainer.defaultDirectoryURL().appending(path: "DevNote-local.sqlite")
        let desc = NSPersistentStoreDescription(url: url)
        desc.shouldMigrateStoreAutomatically = true
        desc.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [desc]
        Self.migrateStoreIfNeeded(at: url)
        Self.loadStores(container, url: url)

        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.name = "viewContext"

        migrateLegacyStoreIfNeeded()

        // Otomatik kaydet: yazarken bile en geç 0.4 sn'de bir. Her kayıt hem iCloud'a hem yakın
        // cihazlara hemen gönderilir; sık kaydetmek gecikmeyi düşürür.
        autosave = NotificationCenter.default
            .publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)
            .filter { [weak self] _ in self?.context.transactionAuthor == nil }
            .throttle(for: .seconds(0.4), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.save() }

        if Self.cloudEnabled {
            Task { await loadIdentity() }
        }
    }

    /// Kullanıcı kaynaklı değişiklikleri kaydeder ve değişiklik zamanını damgalar
    /// (çakışmada son yazan kazanır).
    func save() {
        guard context.hasChanges else { return }
        let now = Date.now
        for object in context.insertedObjects.union(context.updatedObjects) where object.hasPersistentChangedValues {
            object.setValue(now, forKey: "modifiedAt_")
        }
        do {
            try context.save()
        } catch {
            lastError = error.localizedDescription
            ErrorReporter.shared.report(error, area: "Kaydetme")
        }
    }

    // MARK: - Kimlik

    @MainActor
    private func loadIdentity() async {
        let ck = CKContainer(identifier: Self.cloudContainerID)
        do {
            guard try await ck.accountStatus() == .available else {
                CloudSync.shared.setStatus("iCloud hesabı yok — yerel çalışıyor")
                return
            }
            let recordID = try await ck.userRecordID()
            me = Person(id: recordID.recordName, name: "Ben", isMe: true)
            PeerSync.shared.start(userID: recordID.recordName)
            TaskNotifier.shared.scheduleRefresh()
        } catch {
            CloudSync.shared.setStatus("iCloud hatası: \(error.localizedDescription)")
        }
    }

    // MARK: - Paylaşım (CloudSync'e yönlendirir)

    /// Bu defter başkası tarafından benimle mi paylaşıldı?
    func isSharedWithMe(_ notebook: Notebook) -> Bool {
        (notebook.zoneOwner_ ?? CKCurrentUserDefaultName) != CKCurrentUserDefaultName
    }

    func existingShare(for notebook: Notebook) -> CKShare? {
        CloudSync.shared.share(forZone: notebook.zoneName_, owner: notebook.zoneOwner_)
    }

    func isShared(_ notebook: Notebook) -> Bool {
        isSharedWithMe(notebook) || existingShare(for: notebook) != nil
    }

    /// Kullanıcı bu nesneyi düzenleyebilir mi? (salt okunur katılımcılar için false)
    func canEdit(_ object: NSManagedObject) -> Bool {
        guard let owner = object.value(forKey: "zoneOwner_") as? String, owner != CKCurrentUserDefaultName,
              let share = CloudSync.shared.share(forZone: object.value(forKey: "zoneName_") as? String, owner: owner),
              let me = share.currentUserParticipant else { return true }
        return me.permission == .readWrite
    }

    /// Paylaşılan defterin katılımcıları (atama listesi için).
    func participants(for notebook: Notebook?) -> [Person] {
        guard let notebook, let share = existingShare(for: notebook) else { return [] }
        return share.participants
            .filter { $0.role == .owner || $0.acceptanceStatus == .accepted }
            .compactMap { participant in
                let isMe = participant == share.currentUserParticipant
                guard let id = isMe ? me.id : participant.userIdentity.userRecordID?.recordName else { return nil }
                return Person(id: id, name: isMe ? "Ben" : Self.displayName(of: participant), isMe: isMe)
            }
            .sorted { ($0.isMe ? 0 : 1, $0.name) < ($1.isMe ? 0 : 1, $1.name) }
    }

    /// Paylaşılan defterlerde blokların "kim ekledi/atadı" bilgisi için kendi adım.
    func myDisplayName(for notebook: Notebook?) -> String? {
        guard let notebook, let share = existingShare(for: notebook),
              let me = share.currentUserParticipant else { return nil }
        return Self.displayName(of: me)
    }

    static func displayName(of participant: CKShare.Participant) -> String {
        if let components = participant.userIdentity.nameComponents {
            let name = PersonNameComponentsFormatter.localizedString(from: components, style: .default)
            if !name.isEmpty { return name }
        }
        return participant.userIdentity.lookupInfo?.emailAddress
            ?? participant.userIdentity.lookupInfo?.phoneNumber
            ?? "Katılımcı"
    }

    /// Davet bağlantısına tıklanınca (AppDelegate/SceneDelegate'ten) çağrılır.
    func accept(_ metadata: CKShare.Metadata) {
        Task { await CloudSync.shared.accept(metadata) }
    }

    // MARK: - Eski depodan taşıma

    /// NSPersistentCloudKitContainer dönemindeki `DevNote.sqlite`'ı bir kez okuyup yeni depoya kopyalar.
    /// uuid'ler korunduğu için iki cihaz da taşısa CloudKit'te tek kayıt oluşur.
    private func migrateLegacyStoreIfNeeded() {
        let key = "migratedLegacyStore-v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let url = NSPersistentContainer.defaultDirectoryURL().appending(path: "DevNote.sqlite")
        guard FileManager.default.fileExists(atPath: url.path),
              (try? context.count(for: Notebook.fetchAll())) == 0 else { return }

        let legacy = NSPersistentContainer(name: "Legacy", managedObjectModel: DataModel.make(legacy: true))
        let desc = NSPersistentStoreDescription(url: url)
        desc.isReadOnly = true
        desc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        legacy.persistentStoreDescriptions = [desc]
        var loadError: Error?
        legacy.loadPersistentStores { _, error in loadError = error }
        if let loadError { ErrorReporter.shared.report(loadError, area: "Eski depo", silent: true); return }
        let old = legacy.viewContext

        func copy(_ entity: String, link: ((NSManagedObject, NSManagedObject) -> Void)? = nil) -> [UUID: NSManagedObject] {
            var map: [UUID: NSManagedObject] = [:]
            let rows = (try? old.fetch(NSFetchRequest<NSManagedObject>(entityName: entity))) ?? []
            for row in rows {
                guard let uuid = row.value(forKey: "uuid_") as? UUID, map[uuid] == nil else { continue }
                let new = NSManagedObject(entity: DataModel.entity(entity), insertInto: context)
                for name in row.entity.attributesByName.keys {
                    new.setValue(row.value(forKey: name), forKey: name)
                }
                link?(row, new)
                map[uuid] = new
            }
            return map
        }

        let notebooks = copy("Notebook") { _, new in
            let nb = new as! Notebook
            nb.zoneName_ = "nb-\(nb.uuid.uuidString)"
            nb.zoneOwner_ = CKCurrentUserDefaultName
        }
        let pages = copy("Page") { row, new in
            if let nbID = (row.value(forKey: "notebook") as? NSManagedObject)?.value(forKey: "uuid_") as? UUID,
               let nb = notebooks[nbID] as? Notebook {
                let page = new as! Page
                let updated = page.updatedAt_
                page.move(to: nb)
                page.updatedAt_ = updated   // taşıma "şimdi düzenlendi" sayılmasın
            }
        }
        _ = copy("Block") { row, new in
            if let pageID = (row.value(forKey: "page") as? NSManagedObject)?.value(forKey: "uuid_") as? UUID,
               let page = pages[pageID] as? Page {
                let block = new as! Block
                block.page = page
                block.zoneName_ = page.zoneName_
                block.zoneOwner_ = page.zoneOwner_
            }
        }
        print("☁️ eski depodan taşındı: \(notebooks.count) defter, \(pages.count) sayfa")
        UserDefaults.standard.set(true, forKey: "didSeedSampleData")
        save()
    }
}

// MARK: - Fetch yardımcıları

extension DataModel {
    static func entity(_ name: String) -> NSEntityDescription { shared.entitiesByName[name]! }
}

extension Notebook {
    static func fetchAll() -> NSFetchRequest<Notebook> {
        let r = NSFetchRequest<Notebook>(entityName: "Notebook")
        r.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true),
                             NSSortDescriptor(key: "createdAt_", ascending: true)]
        return r
    }
}

extension Page {
    static func fetchAll() -> NSFetchRequest<Page> {
        let r = NSFetchRequest<Page>(entityName: "Page")
        r.sortDescriptors = [NSSortDescriptor(key: "updatedAt_", ascending: false)]
        return r
    }
}

extension Block {
    static func fetchAll(predicate: NSPredicate? = nil) -> NSFetchRequest<Block> {
        let r = NSFetchRequest<Block>(entityName: "Block")
        r.predicate = predicate
        r.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]
        return r
    }
}

extension Persistence {
    /// Depo açılamazsa uygulamayı kapatmak yerine: bozuk dosyayı kenara al ve yenisini aç; o da olmazsa
    /// geçici (bellekte) depoyla devam et. iCloud'daki veriler senkronla geri gelir.
    fileprivate static func loadStores(_ container: NSPersistentContainer, url: URL) {
        var failure: Error?
        container.loadPersistentStores { _, error in failure = error }
        guard let failure else { return }
        ErrorReporter.shared.report(failure, area: "Veri deposu")

        let backup = url.deletingLastPathComponent()
            .appending(path: "DevNote-local-bozuk-\(Int(Date.now.timeIntervalSince1970)).sqlite")
        do {
            try container.persistentStoreCoordinator.replacePersistentStore(
                at: backup, withPersistentStoreFrom: url, type: .sqlite)
            try container.persistentStoreCoordinator.destroyPersistentStore(at: url, type: .sqlite)
        } catch {
            ErrorReporter.shared.report(error, area: "Veri deposu", silent: true)
        }
        var retry: Error?
        container.loadPersistentStores { _, error in retry = error }
        guard retry != nil else {
            ErrorReporter.shared.report(message: "Yerel depo onarıldı, eski dosya yedeklendi: \(backup.lastPathComponent)",
                                        area: "Veri deposu")
            return
        }
        let memory = NSPersistentStoreDescription()
        memory.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [memory]
        container.loadPersistentStores { _, _ in }
        ErrorReporter.shared.report(message: "Yerel depo açılamadı; bu oturum geçici bellekte çalışıyor.", area: "Veri deposu")
    }
}

extension Persistence {
    /// Depo eski bir model sürümündeyse taşımadan önce yedekler. Taşımayı Core Data kendisi yapar
    /// (SQLite deposu modelin bir kopyasını içerdiği için eski sürümü bundle'da aramaya gerek kalmaz).
    fileprivate static func migrateStoreIfNeeded(at url: URL) {
        let dir = url.deletingLastPathComponent()
        // Önceki sürümün yarım bıraktığı geçici dosyalar
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: dir.appending(path: "DevNote-local-tasiniyor.sqlite" + suffix))
        }
        guard FileManager.default.fileExists(atPath: url.path),
              let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url),
              !DataModel.shared.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) else { return }

        let version = (0..<DataModel.currentVersion).reversed().first {
            DataModel.make(version: $0, generic: true).isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
        }
        let label = version.map { "v\($0)" } ?? "eski"
        let backup = dir.appending(path: "DevNote-local-\(label)-yedek.sqlite")
        do {
            try NSPersistentStoreCoordinator(managedObjectModel: DataModel.make(version: version ?? 1, generic: true))
                .replacePersistentStore(at: backup, withPersistentStoreFrom: url, type: .sqlite)
            print("🗄️ veri modeli \(label) → v\(DataModel.currentVersion); yedek: \(backup.lastPathComponent)")
        } catch {
            ErrorReporter.shared.report(error, area: "Veri yedeği", silent: true)
        }
    }
}
