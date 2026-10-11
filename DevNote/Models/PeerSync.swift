import Foundation
import CoreData
import CryptoKit
import Network

/// Hızlı yol: aynı iCloud hesabındaki yakın cihazlar (aynı Wi‑Fi, doğrudan Wi‑Fi ya da USB) Bonjour ile
/// birbirini bulur ve her kaydı anında doğrudan karşıya iletir. Kalıcı senkron iCloud'dadır (CloudSync);
/// buradan gelen değişiklikler iCloud'a tekrar gönderilmez — onları zaten kaynak cihaz gönderir.
/// Kayıt adları uuid olduğu için iki yol aynı nesnede buluşur, çift kayıt oluşmaz.
///
/// Güvenlik: TLS-PSK. Anahtar iCloud kullanıcı kimliğinden türetilir; başka bir hesabın cihazı
/// el sıkışmayı geçemez, trafik şifrelidir.
final class PeerSync: ObservableObject {
    static let shared = PeerSync()
    static let serviceType = "_devnote-sync._tcp"
    /// Uzaktan uygulanan kayıtları yeniden yayınlamamak için transactionAuthor.
    static let peerAuthor = "peer"

    @Published private(set) var connectedNames: [String] = []

    private let instanceID = UUID().uuidString
    /// Kalıcı cihaz kimliği: uygulama yeniden açılsa da aynı cihaz tek kez listelenir.
    private let deviceID: String = {
        if let id = UserDefaults.standard.string(forKey: "peerDeviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "peerDeviceID")
        return id
    }()
    private let deviceName: String
    private var userHash: String?
    private var psk: SymmetricKey?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peers: [ObjectIdentifier: Peer] = [:]
    /// Henüz hazır olmayan bağlantılar (bellekte tutulmazsa hemen serbest kalırlar)
    private var connecting: [ObjectIdentifier: Peer] = [:]
    /// Bizim başlattığımız bağlantılar (servis adı → peer); aynı cihaza iki kez bağlanmamak için
    private var outgoing: [String: Peer] = [:]
    private var pendingChanges: [[String: Any]] = []
    private var observers: [NSObjectProtocol] = []

    private init() {
        #if os(macOS)
        deviceName = Host.current().localizedName ?? "Mac"
        #else
        deviceName = "iPhone"
        #endif
    }

    // MARK: - Yaşam döngüsü

    /// iCloud kimliği belli olunca çağrılır; yalnızca aynı kullanıcının cihazları eşleşir.
    func start(userID: String) {
        // Test için: yalnızca iCloud yolunu ölçmek istersen DEVNOTE_NO_PEER=1
        guard userHash == nil, ProcessInfo.processInfo.environment["DEVNOTE_NO_PEER"] == nil else { return }
        userHash = SHA256.hash(data: Data("devnote-user:\(userID)".utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        psk = SymmetricKey(data: HMAC<SHA256>.authenticationCode(
            for: Data("devnote-peer-sync-v1".utf8), using: SymmetricKey(data: Data(userID.utf8))))
        observeSaves()
        startNetworking()
    }

    /// Uygulama ön plana dönünce (iOS arka planda bağlantıları düşürür) yeniden bağlan.
    func resume() {
        guard userHash != nil, peers.isEmpty else { return }
        stopNetworking()
        startNetworking()
    }

    private func parameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        if let psk {
            let key = psk.withUnsafeBytes { DispatchData(bytes: $0) }
            let hint = Data("devnote".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                                                    key as __DispatchData, hint as __DispatchData)
            sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                        tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.noDelay = true
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }

    private func startNetworking() {
        guard let userHash else { return }
        do {
            let listener = try NWListener(using: parameters())
            listener.service = NWListener.Service(name: instanceID, type: Self.serviceType, domain: nil,
                                                  txtRecord: NWTXTRecord(["u": userHash]))
            listener.newConnectionHandler = { [weak self] connection in
                self?.add(Peer(connection: connection), serviceName: nil)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.retryLater() }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            ErrorReporter.shared.report(error, area: "Yakın cihaz", silent: true)
        }

        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.connect(to: results) }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func stopNetworking() {
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        (Array(peers.values) + Array(connecting.values)).forEach { $0.connection.cancel() }
        peers = [:]; connecting = [:]; outgoing = [:]
        connectedNames = []
    }

    private func retryLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            if listener?.state != .ready { stopNetworking(); startNetworking() }
            else if let results = browser?.browseResults { connect(to: results) }
        }
    }

    private func connect(to results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint,
                  name != instanceID, outgoing[name] == nil else { continue }
            if case let .bonjour(txt) = result.metadata, txt["u"] != userHash { continue }
            // Çift bağlantı olmasın: yalnızca küçük kimlikli taraf bağlanır
            guard instanceID < name else { continue }
            let peer = Peer(connection: NWConnection(to: result.endpoint, using: parameters()))
            add(peer, serviceName: name)
        }
    }

    private func add(_ peer: Peer, serviceName: String?) {
        let key = ObjectIdentifier(peer)
        connecting[key] = peer
        if let serviceName { outgoing[serviceName] = peer }
        peer.onReady = { [weak self, weak peer] in
            guard let self, let peer else { return }
            connecting[key] = nil
            peers[key] = peer
            peer.send(["hello": deviceName, "device": deviceID])
        }
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            if let name = message["hello"] as? String {
                peer.name = name
                peer.deviceID = message["device"] as? String
                // Aynı cihazdan eski bir bağlantı kaldıysa (uygulama yeniden açıldı vb.) onu kapat
                for (otherKey, other) in peers where otherKey != key && other.deviceID == peer.deviceID {
                    peers[otherKey] = nil
                    other.connection.cancel()
                }
                updateNames()
                print("⚡ \(name) bağlandı")
                sendSnapshot(to: peer)
            } else if let changes = message["changes"] as? [[String: Any]] {
                apply(changes)
            }
        }
        peer.onClose = { [weak self] in
            guard let self else { return }
            peers[key] = nil
            connecting[key] = nil
            if let serviceName { outgoing[serviceName] = nil }
            updateNames()
            retryLater()
        }
        peer.start()
    }

    private func updateNames() {
        // Cihaz başına tek isim
        var seen = Set<String>()
        connectedNames = peers.values.compactMap { peer -> String? in
            guard let name = peer.name, seen.insert(peer.deviceID ?? name).inserted else { return nil }
            return name
        }.sorted()
    }

    // MARK: - Yerel değişiklikleri yakala & gönder

    private func observeSaves() {
        let context = Persistence.shared.context
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextWillSave, object: context, queue: nil) { [weak self] _ in
            self?.captureChanges(in: context)
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave, object: context, queue: nil) { [weak self] _ in
            self?.flush()
        })
    }

    private func captureChanges(in context: NSManagedObjectContext) {
        // Buluttan / yakın cihazdan gelen kayıtları yeniden yayınlama
        guard context.transactionAuthor == nil else { pendingChanges = []; return }
        var changes: [[String: Any]] = []
        for object in context.insertedObjects.union(context.updatedObjects) where object.hasPersistentChangedValues {
            if let change = Self.encode(object) { changes.append(change) }
        }
        for object in context.deletedObjects {
            if let uuid = object.value(forKey: "uuid_") as? UUID {
                changes.append(["op": "delete", "entity": object.entity.name ?? "", "uuid": uuid.uuidString])
            }
        }
        pendingChanges = changes
    }

    private func flush() {
        let changes = pendingChanges
        pendingChanges = []
        guard !changes.isEmpty, !peers.isEmpty else { return }
        peers.values.forEach { $0.send(["v": 1, "changes": changes]) }
    }

    // MARK: - İlk eşitleme

    /// Bağlanınca karşıya, o cihazla son görüşmeden beri değişen her şeyi gönder (ilk görüşmede tümünü).
    /// Böylece boş açılan bir cihaz (ör. iCloud çalışmıyorken) mevcut notları da alır; çakışmada son yazan kazanır.
    private func sendSnapshot(to peer: Peer) {
        let defaultsKey = "peerSnapshot.\(peer.deviceID ?? peer.name ?? "?")"
        // Saat farkları ve yolda kalan değişiklikler için biraz geriden başla
        let since = (UserDefaults.standard.object(forKey: defaultsKey) as? Date)?.addingTimeInterval(-600)
        let started = Date.now
        let context = Persistence.shared.context
        var batch: [[String: Any]] = []
        var batchBytes = 0
        var total = 0

        func flushBatch() {
            guard !batch.isEmpty else { return }
            peer.send(["v": 1, "changes": batch])
            total += batch.count
            batch = []
            batchBytes = 0
        }

        for entity in EntityGraph.entities.sorted(by: { (EntityGraph.order[$0] ?? 9) < (EntityGraph.order[$1] ?? 9) }) {
            guard let description = DataModel.shared.entitiesByName[entity] else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            if let since, description.attributesByName["modifiedAt_"] != nil {
                request.predicate = NSPredicate(format: "modifiedAt_ == nil OR modifiedAt_ > %@", since as NSDate)
            }
            let objects: [NSManagedObject]
            do { objects = try context.fetch(request) } catch {
                ErrorReporter.shared.report(error, area: "Yakın cihaz", silent: true)
                continue
            }
            for object in objects {
                guard let change = Self.encode(object) else { continue }
                batch.append(change)
                batchBytes += (change["attrs"] as? [String: Any])?.values.reduce(0) { $0 + (($1 as? String)?.utf8.count ?? 16) } ?? 0
                // Görseller büyük; mesajları ~1 MB'lık parçalara böl (ebeveyn sırası korunur)
                if batchBytes > 1_000_000 || batch.count >= 300 { flushBatch() }
            }
        }
        flushBatch()
        UserDefaults.standard.set(started, forKey: defaultsKey)
        if total > 0 { print("⚡ \(peer.name ?? "cihaz") cihazına \(total) kayıt gönderildi") }
    }

    // MARK: - Kodlama

    private static func encode(_ object: NSManagedObject) -> [String: Any]? {
        guard let uuid = object.value(forKey: "uuid_") as? UUID, let entity = object.entity.name else { return nil }
        var attrs: [String: Any] = [:]
        for name in object.entity.attributesByName.keys where !["uuid_", "ckSystemFields_", "parentUUID_"].contains(name) {
            switch object.value(forKey: name) {
            case nil: attrs[name] = NSNull()
            case let date as Date: attrs[name] = date.timeIntervalSinceReferenceDate
            case let id as UUID: attrs[name] = id.uuidString
            case let data as Data: attrs[name] = data.base64EncodedString()   // JSON ikili veri taşımaz
            case let value?: attrs[name] = value
            }
        }
        var change: [String: Any] = ["op": "upsert", "entity": entity, "uuid": uuid.uuidString, "attrs": attrs]
        let parent = EntityGraph.parentObject(of: object)
        if let parentID = parent?.value(forKey: "uuid_") as? UUID { change["parent"] = parentID.uuidString }
        return change
    }

    // MARK: - Uzaktan gelen değişiklikleri uygula

    private static let entityOrder = EntityGraph.order

    private func apply(_ changes: [[String: Any]]) {
        let persistence = Persistence.shared
        let context = persistence.context
        persistence.save()   // önce bekleyen yerel değişiklikleri kaydet (ve yayınla)

        let upserts = changes.filter { $0["op"] as? String == "upsert" }
            .sorted { Self.entityOrder[$0["entity"] as? String ?? ""] ?? 9 < Self.entityOrder[$1["entity"] as? String ?? ""] ?? 9 }
        let deletes = changes.filter { $0["op"] as? String == "delete" }

        let previous = context.transactionAuthor
        context.transactionAuthor = Self.peerAuthor
        defer { context.transactionAuthor = previous }

        for change in upserts {
            guard let entityName = change["entity"] as? String, let uuidString = change["uuid"] as? String,
                  let uuid = UUID(uuidString: uuidString), let attrs = change["attrs"] as? [String: Any],
                  let entity = DataModel.shared.entitiesByName[entityName] else { continue }

            let parent = (change["parent"] as? String).flatMap(UUID.init(uuidString:)).flatMap { id in
                EntityGraph.parent[entityName].flatMap { Self.find($0.entity, id, in: context) }
            }
            let existing = Self.find(entityName, uuid, in: context)
            // Son yazan kazanır
            if let existing, let local = existing.value(forKey: "modifiedAt_") as? Date,
               let remote = (attrs["modifiedAt_"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:)),
               local > remote { continue }
            let object = existing ?? {
                let created = NSManagedObject(entity: entity, insertInto: context)
                created.setValue(uuid, forKey: "uuid_")
                return created
            }()

            for (name, raw) in attrs {
                guard let desc = entity.attributesByName[name] else { continue }
                let value: Any? = switch (desc.attributeType, raw) {
                case (_, is NSNull): nil
                case (.dateAttributeType, let t as Double): Date(timeIntervalSinceReferenceDate: t)
                case (.UUIDAttributeType, let s as String): UUID(uuidString: s)
                case (.binaryDataAttributeType, let s as String): Data(base64Encoded: s)
                default: raw
                }
                let current = object.value(forKey: name)
                if (current as AnyObject?)?.isEqual(value) != true && !(current == nil && value == nil) {
                    object.setValue(value, forKey: name)
                }
            }
            if let parent {
                let key = EntityGraph.parent[entityName]?.key ?? "notebook"
                if object.value(forKey: key) as? NSManagedObject != parent { object.setValue(parent, forKey: key) }
            }
        }

        for change in deletes {
            guard let entityName = change["entity"] as? String,
                  let uuid = (change["uuid"] as? String).flatMap(UUID.init(uuidString:)),
                  let object = Self.find(entityName, uuid, in: context) else { continue }
            context.delete(object)
        }

        if context.hasChanges { try? context.save() }
        Task { @MainActor in TaskNotifier.shared.scheduleRefresh() }
    }

    private static func find(_ entity: String, _ uuid: UUID, in context: NSManagedObjectContext) -> NSManagedObject? {
        // Daha yeni bir sürümden gelen, bu sürümün bilmediği tür (Core Data bilinmeyen varlıkta çöker)
        guard DataModel.shared.entitiesByName[entity] != nil else { return nil }
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "uuid_ == %@", uuid as NSUUID)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }
}

// MARK: - Bağlantı (uzunluk önekli JSON mesajları)

private final class Peer {
    let connection: NWConnection
    var name: String?
    var deviceID: String?
    var onReady: (() -> Void)?
    var onMessage: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?
    private var buffer = Data()
    private var closed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onReady?()
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func send(_ message: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var length = UInt32(body.count).bigEndian
        let frame = Data(bytes: &length, count: 4) + body
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { buffer.append(data); drain() }
            if isComplete || error != nil { connection.cancel(); close() } else { receive() }
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
            guard buffer.count >= 4 + length else { return }
            let body = buffer.dropFirst(4).prefix(length)
            buffer = Data(buffer.dropFirst(4 + length))
            if let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                onMessage?(message)
            }
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        onClose?()
    }
}
