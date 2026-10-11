import CloudKit
import CoreData
import SwiftUI

// iCloud paylaşım davetleri (bağlantıya tıklanınca) uygulamaya buradan gelir.

#if os(iOS)
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // CloudKit değişikliklerini sessiz push ile alabilmek için
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        // Uygulama kapalıyken davet bağlantısıyla açıldıysa
        if let metadata = options.cloudKitShareMetadata {
            Persistence.shared.accept(metadata)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Persistence.shared.accept(metadata)
    }
}

#elseif os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Persistence.shared.accept(metadata)
    }
}
#endif

/// ShareLink ile paylaşılabilen defter. Yeni paylaşım hazırlar ya da mevcut paylaşımı yönetir
/// (kişi ekle/çıkar, yetki değiştir, paylaşımı durdur).
/// Paylaşım ekranına verilen öğe. CloudKit `transferRepresentation`'ı arka planda çağırır; bu yüzden
/// mevcut paylaşım öğe oluşturulurken (ana iş parçacığında) hazırlanır, orada Core Data'ya dokunulmaz.
struct NotebookShareItem: Transferable, @unchecked Sendable {
    let objectID: NSManagedObjectID
    let existing: CKShare?

    @MainActor
    init(notebook: Notebook) {
        objectID = notebook.objectID
        existing = Persistence.shared.existingShare(for: notebook)
    }

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { item in
            let container = CKContainer(identifier: Persistence.cloudContainerID)
            if let existing = item.existing {
                return .existing(existing, container: container)
            }
            return .prepareShare(container: container) {
                try await makeShare(item.objectID)
            }
        }
    }

    @MainActor
    private static func makeShare(_ id: NSManagedObjectID) async throws -> CKShare {
        guard let notebook = Persistence.shared.context.object(with: id) as? Notebook else {
            throw CKError(.unknownItem)
        }
        return try await CloudSync.shared.makeShare(for: notebook)
    }
}
