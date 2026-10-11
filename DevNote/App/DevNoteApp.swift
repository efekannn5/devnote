import SwiftUI
import CoreData

@main
struct DevNoteApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @StateObject private var persistence = Persistence.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // İlk iş: hata/çökme kaydını kur (önceki oturum çöktüyse burada bildirilir)
        ErrorReporter.shared.install()
        let persistence = Persistence.shared
        #if os(macOS)
        // Örnek içerik yalnızca Mac'te oluşur; iPhone iCloud'dan alır (çift kayıt olmasın).
        SampleData.seedIfNeeded(persistence.context)
        MCPServer.shared.start(context: persistence.context)
        #endif
        // iCloud senkronu hemen başlar (hesap hazır olana kadar CKSyncEngine değişiklikleri kuyrukta tutar);
        // böylece arka planda açılıp (ör. Dynamic Island ✓) yapılan değişiklikler de kaybolmaz.
        if Persistence.cloudEnabled { CloudSync.shared.start() }
        TaskActions.install()
        TaskNotifier.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, persistence.context)
                .environmentObject(persistence)
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 560)
                .environmentObject(MCPServer.shared)
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { PeerSync.shared.resume() } else { persistence.save() }
            CloudSync.shared.setActive(phase == .active)
        }
        #if os(macOS)
        .windowToolbarStyle(.unified)
        .commands { FormatMenuCommands() }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(MCPServer.shared)
                .environmentObject(persistence)
        }
        #endif
    }
}
