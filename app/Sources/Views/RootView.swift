// Màn chính: bottom tab — Metrics · Terminal · SFTP · 2 Server.
import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            MetricsListView()
                .tabItem { Label("Metrics", systemImage: "gauge.with.dots.needle.67percent") }
            HostPickerList(action: .terminal, title: "Terminal")
                .tabItem { Label("Terminal", systemImage: "terminal") }
            HostPickerList(action: .sftp, title: "SFTP")
                .tabItem { Label("SFTP", systemImage: "folder") }
            DockerHostsView()
                .tabItem { Label("Docker", systemImage: "shippingbox") }
            NavigationStack { DualPaneView() }
                .tabItem { Label("2 Server", systemImage: "rectangle.split.2x1") }
        }
    }
}

enum HostAction { case terminal, sftp, docker }

// Danh sách host dùng chung cho 3 tab; chạm host để mở terminal / SFTP / metrics.
struct HostPickerList: View {
    @Environment(AppModel.self) private var model
    let action: HostAction
    let title: String
    @State private var editingHost: Host?
    @State private var showHostSheet = false

    var body: some View {
        NavigationStack {
            List {
                Section("Máy chủ") {
                    ForEach(model.hosts) { host in
                        NavigationLink(value: host) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.label.isEmpty ? host.host : host.label).fontWeight(.medium)
                                Text("\(host.username)@\(host.host):\(host.port)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button("Sửa") { editingHost = host; showHostSheet = true }
                            Button("Xóa", role: .destructive) { model.delete(host: host) }
                        }
                    }
                    if model.hosts.isEmpty {
                        Text("Chưa có host — bấm icon server ở góc trên để thêm.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(title)
            .navigationDestination(for: Host.self) { host in destination(host) }
            .toolbar {
                ToolbarItem { NavigationLink { KeysView() } label: { Image(systemName: "key") } }
                ToolbarItem { NavigationLink { ServerListView() } label: { Image(systemName: "server.rack") } }
            }
            .sheet(isPresented: $showHostSheet) { HostEditView(host: editingHost) }
        }
    }

    @ViewBuilder
    private func destination(_ host: Host) -> some View {
        switch action {
        case .terminal: TerminalHostView(host: host)
        case .sftp:
            SingleBrowser(host: host)
                .navigationTitle(host.label.isEmpty ? host.host : host.label)
        case .docker: DockerView(host: host)
        }
    }
}

// Terminal cho một host.
struct TerminalHostView: View {
    @Environment(AppModel.self) private var model
    let host: Host
    var body: some View {
        TerminalScreenView(config: model.config(for: host), manager: model.ssh)
            .navigationTitle(host.label.isEmpty ? host.host : host.label)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }
}
