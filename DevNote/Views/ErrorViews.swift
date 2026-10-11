import SwiftUI

/// Ekranın üstünden kayan hata uyarısı. Uygulamayı durdurmaz; birkaç saniye sonra kendiliğinden kapanır.
struct ErrorBannerHost: ViewModifier {
    @ObservedObject private var reporter = ErrorReporter.shared
    @State private var showingLog = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let issue = reporter.banner {
                    ErrorBanner(issue: issue,
                                details: { showingLog = true; reporter.banner = nil },
                                dismiss: { reporter.banner = nil })
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(issue.id)
                        .task(id: issue.id) {
                            try? await Task.sleep(for: .seconds(issue.isCrash ? 10 : 6))
                            if reporter.banner == issue { reporter.banner = nil }
                        }
                }
            }
            .animation(Theme.spring, value: reporter.banner)
            .sheet(isPresented: $showingLog) { ErrorLogView() }
    }
}

extension View {
    func errorBanner() -> some View { modifier(ErrorBannerHost()) }
}

struct ErrorBanner: View {
    let issue: ErrorReporter.Issue
    let details: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: issue.isCrash ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(issue.isCrash ? .red : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.isCrash ? "Uygulama geçen sefer kapandı" : "\(issue.area) hatası")
                    .font(.subheadline.weight(.semibold))
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text("Kaydedildi · uygulamaya devam edebilirsin")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.caption.weight(.bold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                Button("Ayrıntı", action: details)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
    }
}

/// Kayıtlı hatalar: bu oturumdakiler + günlük dosyasının tamamı (paylaşılabilir).
struct ErrorLogView: View {
    @ObservedObject private var reporter = ErrorReporter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var log = ""

    var body: some View {
        NavigationStack {
            List {
                if reporter.recent.isEmpty && log.isEmpty {
                    ContentUnavailableView("Kayıtlı hata yok", systemImage: "checkmark.seal",
                                           description: Text("Bir sorun olursa burada görünür."))
                }
                if !reporter.recent.isEmpty {
                    Section("Bu oturum") {
                        ForEach(reporter.recent) { issue in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(issue.area).font(.caption.weight(.semibold))
                                        .foregroundStyle(issue.isCrash ? .red : .orange)
                                    Spacer()
                                    Text(issue.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(issue.message).font(.callout).textSelection(.enabled)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                if !log.isEmpty {
                    Section("Günlük dosyası") {
                        Text(log.split(separator: "\n").suffix(300).joined(separator: "\n"))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Hata Kayıtları")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { dismiss() }
                }
                ToolbarItemGroup(placement: .automatic) {
                    if !log.isEmpty {
                        ShareLink(item: reporter.logURL) {
                            Label("Paylaş", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button("Temizle", systemImage: "trash", role: .destructive) {
                        reporter.clearLog()
                        log = ""
                    }
                    .disabled(reporter.recent.isEmpty && log.isEmpty)
                }
            }
            .task { log = reporter.readLog() }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 440)
        #endif
    }
}
