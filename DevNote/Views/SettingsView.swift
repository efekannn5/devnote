#if os(macOS)
import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var mcp: MCPServer
    @State private var portText = ""

    private var claudeCommand: String { "claude mcp add --transport http devnote \(mcp.endpoint)" }
    private var jsonConfig: String {
        """
        {
          "mcpServers": {
            "devnote": { "type": "http", "url": "\(mcp.endpoint)" }
          }
        }
        """
    }
    private var bridgeConfig: String {
        """
        {
          "mcpServers": {
            "devnote": { "command": "npx", "args": ["-y", "mcp-remote", "\(mcp.endpoint)"] }
          }
        }
        """
    }

    var body: some View {
        TabView {
            Form {
                Section {
                    Toggle("Yerel MCP sunucusunu çalıştır", isOn: $mcp.enabled)
                    HStack {
                        TextField("Port", text: $portText)
                            .frame(width: 90)
                            .onSubmit(applyPort)
                        Button("Uygula", action: applyPort)
                        Spacer()
                        Label(mcp.isRunning ? "Çalışıyor" : "Kapalı",
                              systemImage: mcp.isRunning ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(mcp.isRunning ? .green : .secondary)
                    }
                    LabeledContent("Adres", value: mcp.endpoint)
                } footer: {
                    Text("Sunucu yalnızca 127.0.0.1 üzerinde dinler; ağdaki diğer cihazlar erişemez.")
                }

                Section("Bağlan") {
                    snippet("Claude Code", claudeCommand)
                    snippet("HTTP destekleyen istemciler (Cursor, VS Code…)", jsonConfig)
                    snippet("Sadece stdio destekleyen istemciler (Claude Desktop)", bridgeConfig)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Yapay Zeka", systemImage: "sparkles") }

            Form {
                Section("iCloud") {
                    #if ICLOUD_SYNC
                    Label("iCloud senkronu açık", systemImage: "icloud.fill").foregroundStyle(.blue)
                    #else
                    Label("iCloud senkronu kapalı (yerel depolama)", systemImage: "icloud.slash")
                    Text("Açmak için README'deki “iCloud” adımlarını izle.").foregroundStyle(.secondary)
                    #endif
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Senkron", systemImage: "icloud") }
        }
        .frame(width: 560, height: 520)
        .onAppear { portText = String(mcp.port) }
    }

    private func applyPort() {
        guard let p = UInt16(portText), p > 1024 else { portText = String(mcp.port); return }
        mcp.port = p
        mcp.restart()
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Button("Kopyala", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
            }
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
#endif
