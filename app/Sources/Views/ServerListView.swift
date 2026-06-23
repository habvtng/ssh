// Màn hình quản lý server: danh sách toàn bộ host + thêm/sửa/xóa.
import SwiftUI

struct ServerListView: View {
    @Environment(AppModel.self) private var model
    @State private var editingHost: Host?
    @State private var showHostSheet = false

    var body: some View {
        List {
            Section("Máy chủ") {
                ForEach(model.hosts) { host in
                    Button {
                        editingHost = host; showHostSheet = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.label.isEmpty ? host.host : host.label)
                                    .fontWeight(.medium)
                                Text("\(host.username)@\(host.host):\(host.port)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                    .swipeActions(edge: .trailing) {
                        Button("Xóa", role: .destructive) { model.delete(host: host) }
                        Button("Sửa") { editingHost = host; showHostSheet = true }
                            .tint(.blue)
                    }
                    .contextMenu {
                        Button { editingHost = host; showHostSheet = true } label: {
                            Label("Sửa", systemImage: "pencil")
                        }
                        Button(role: .destructive) { model.delete(host: host) } label: {
                            Label("Xóa", systemImage: "trash")
                        }
                    }
                }
                if model.hosts.isEmpty {
                    Text("Chưa có server — bấm ＋ để thêm.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Server")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem {
                Button { editingHost = nil; showHostSheet = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showHostSheet) { HostEditView(host: editingHost) }
    }
}
