// Quản lý khóa SSH. Private key + passphrase lưu Keychain.
import SwiftUI

struct KeysView: View {
    @Environment(AppModel.self) private var model
    @State private var showSheet = false

    var body: some View {
        List {
            ForEach(model.keys) { key in
                HStack {
                    Image(systemName: "key.fill").foregroundStyle(.secondary)
                    Text(key.name)
                    Spacer()
                }
                .contextMenu {
                    Button("Xóa", role: .destructive) { model.delete(key: key) }
                }
            }
            if model.keys.isEmpty {
                Text("Chưa có khóa nào").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Khóa SSH")
        .toolbar {
            ToolbarItem {
                Button { showSheet = true } label: { Label("Thêm khóa", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showSheet) { KeyEditView() }
    }
}

struct KeyEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var privateKey = ""
    @State private var passphrase = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Tên") { TextField("id_ed25519", text: $name) }
                Section("Private key (OpenSSH/PEM)") {
                    TextEditor(text: $privateKey)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 160)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
                Section("Passphrase (nếu có)") { SecureField("passphrase", text: $passphrase) }
            }
            .formStyle(.grouped)
            .navigationTitle("Khóa mới")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        var k = SSHKey(); k.name = name.isEmpty ? "key" : name
                        model.upsert(key: k, privateKey: privateKey, passphrase: passphrase)
                        dismiss()
                    }.disabled(privateKey.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 460)
        #endif
    }
}
