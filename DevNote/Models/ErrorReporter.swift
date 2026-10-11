import Foundation
import Darwin
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Uygulamanın her yerinden gelen hataları toplar:
///  - kalıcı günlüğe yazar (Application Support/Logs/devnote-errors.log),
///  - ekranın üstünde kısa bir uyarı gösterir (uygulama arka plandaysa bildirim atar),
///  - uygulamayı kapatmaz; kullanıcı kaldığı yerden devam eder.
/// Gerçek bir çökme (Swift'in durdurduğu hatalar) önlenemez; o durumda son anda kayıt düşülür ve
/// bir sonraki açılışta "Uygulama beklenmedik şekilde kapandı" uyarısı gösterilir.
final class ErrorReporter: ObservableObject, @unchecked Sendable {
    static let shared = ErrorReporter()

    struct Issue: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let area: String
        let message: String
        var isCrash = false
    }

    /// Ekranda gösterilen uyarı
    @MainActor @Published var banner: Issue?
    /// Bu oturumdaki kayıtlar (en yeni başta)
    @MainActor @Published private(set) var recent: [Issue] = []

    let logURL: URL
    private let crashURL: URL
    private let queue = DispatchQueue(label: "devnote.errors")
    private var lastShown: [String: Date] = [:]

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appending(path: "devnote-errors.log")
        crashURL = dir.appending(path: "last-crash.txt")
    }

    // MARK: - Raporlama

    /// - Parameters:
    ///   - area: Hatanın geldiği yer ("iCloud", "Kaydetme", "MCP" …)
    ///   - silent: Yalnızca günlüğe yaz (kendiliğinden düzelen ağ hataları gibi)
    func report(_ error: Error, area: String, silent: Bool = false) {
        report(message: Self.describe(error), area: area, silent: silent)
    }

    func report(message: String, area: String, silent: Bool = false) {
        let issue = Issue(date: .now, area: area, message: message)
        queue.async { self.append(issue) }
        print("⚠️ [\(area)] \(message)")
        guard !silent else { return }
        Task { @MainActor in self.show(issue) }
    }

    @MainActor
    private func show(_ issue: Issue) {
        recent.insert(issue, at: 0)
        if recent.count > 100 { recent.removeLast(recent.count - 100) }

        // Aynı hata 60 sn içinde tekrar gelirse yeniden göstermeyelim (ör. ağ yokken her deneme)
        let key = issue.area + issue.message
        if let last = lastShown[key], Date.now.timeIntervalSince(last) < 60 { return }
        lastShown[key] = .now

        if Self.isAppActive {
            banner = issue
        } else {
            let content = UNMutableNotificationContent()
            content.title = issue.isCrash ? "DevNote beklenmedik şekilde kapandı" : "DevNote · \(issue.area) hatası"
            content.body = issue.message
            content.threadIdentifier = "devnote-errors"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: issue.id.uuidString,
                                                                         content: content, trigger: nil))
        }
    }

    @MainActor
    private static var isAppActive: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState != .background   // açılış sırasında .inactive
        #else
        NSApplication.shared.isActive
        #endif
    }

    private func append(_ issue: Issue) {
        let line = "[\(issue.date.ISO8601Format())] [\(issue.area)] \(issue.message)\n"
        rotateIfNeeded()
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    private func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
        guard size > 1_000_000 else { return }
        let old = logURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: logURL, to: old)
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = error.localizedDescription
        if let reason = ns.localizedFailureReason, !text.contains(reason) { text += " — \(reason)" }
        return "\(text) (\(ns.domain) \(ns.code))"
    }

    // MARK: - Günlük

    func readLog() -> String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    @MainActor
    func clearLog() {
        queue.async { try? FileManager.default.removeItem(at: self.logURL) }
        recent.removeAll()
        banner = nil
    }

    // MARK: - Çökme yakalama

    /// Ham çökme kaydından kısa, anlaşılır açıklama
    private static func crashSummary(_ crash: String) -> String {
        let first = crash.split(separator: "\n").first.map(String.init) ?? ""
        if first.hasPrefix("Objective-C") {
            // "Objective-C istisnası: <ad> — <neden>" → nedeni göster ki ekran görüntüsünden anlaşılsın
            let reason = first.components(separatedBy: " — ").dropFirst().joined(separator: " — ")
            return "Önceki oturum kapandı: \(reason.isEmpty ? "beklenmeyen istisna" : String(reason.prefix(160))). Ayrıntılar kayıtlarda."
        }
        let names = ["04": "geçersiz komut", "05": "programlama hatası (ör. dizi sınırı, boş değer)",
                     "06": "işlem iptal edildi", "08": "hesaplama hatası", "10": "bellek erişim hatası",
                     "11": "bellek erişim hatası"]
        let code = first.split(separator: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: ")")) ?? ""
        let reason = names[code] ?? "bilinmeyen hata"
        return "Önceki oturum kapandı: \(reason). Ayrıntılar hata kayıtlarında."
    }

    /// Açılışta bir kez çağrılır: önceki oturum çöktüyse bildirir, yeni çökmeler için son anda kayıt düşer.
    func install() {
        if let crash = try? String(contentsOf: crashURL, encoding: .utf8), !crash.isEmpty {
            try? FileManager.default.removeItem(at: crashURL)
            var issue = Issue(date: .now, area: "Çökme", message: Self.crashSummary(crash))
            issue.isCrash = true
            queue.async { self.append(Issue(date: issue.date, area: "Çökme", message: crash)) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))   // arayüz hazır olsun
                self.show(issue)
            }
        }

        crashFD = open(crashURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        NSSetUncaughtExceptionHandler { exception in
            let text = "Objective-C istisnası: \(exception.name.rawValue) — \(exception.reason ?? "")\n"
                + exception.callStackSymbols.prefix(25).joined(separator: "\n") + "\n"
            writeCrash(text)
        }
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig, crashSignalHandler)
        }
    }
}

// Sinyal işleyicide yalnızca "async-signal-safe" çağrılar: önceden açılmış dosyaya write + backtrace_symbols_fd.
nonisolated(unsafe) private var crashFD: Int32 = -1

private func writeCrash(_ text: String) {
    guard crashFD >= 0 else { return }
    text.withCString { _ = write(crashFD, $0, strlen($0)) }
}

nonisolated(unsafe) private var crashWritten = false

private let crashSignalHandler: @convention(c) (Int32) -> Void = { sig in
    // Birden çok iş parçacığı aynı anda düşebilir; kaydı bir kez yaz
    if crashFD >= 0 && !crashWritten {
        crashWritten = true
        let header: StaticString = "Uygulama durduruldu (sinyal "
        _ = write(crashFD, header.utf8Start, header.utf8CodeUnitCount)
        var digits: (UInt8, UInt8, UInt8) = (UInt8(48 + (sig / 10) % 10), UInt8(48 + sig % 10), 10)
        withUnsafeBytes(of: &digits) { _ = write(crashFD, $0.baseAddress, 2) }
        let tail: StaticString = ")\n"
        _ = write(crashFD, tail.utf8Start, tail.utf8CodeUnitCount)
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 40)
        let count = backtrace(&frames, 40)
        backtrace_symbols_fd(&frames, count, crashFD)
    }
    // Varsayılan davranışa dön ve sistemin kendi çökme raporunu da üretmesine izin ver
    signal(sig, SIG_DFL)
    raise(sig)
}
