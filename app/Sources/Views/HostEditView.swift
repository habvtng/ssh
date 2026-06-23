// Form thêm/sửa host. Credential ghi vào Keychain qua AppModel.
import SwiftUI

struct HostEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var host = ""
    @State private var port = 22
    @State private var username = "root"
    @State private var authType: AuthType = .password
    @State private var password = ""
    @State private var keyId: UUID?

    let editing: Host?
    init(host: Host?) { self.editing = host }

    var body: some View {
        NavigationStack {
            Form {
                Section("Thông tin") {
                    TextField("Tên hiển thị", text: $label)
                    TextField("Host / IP", text: $host)
                        .textContentType(.URL)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    TextField("Port", value: $port, format: .number)
                    TextField("Username", text: $username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
                Section("Xác thực") {
                    Picker("Phương thức", selection: $authType) {
                        ForEach(AuthType.allCases) { Text($0.label).tag($0) }
                    }
                    if authType == .password {
                        SecureField("Mật khẩu", text: $password)
                    } else {
                        Picker("Khóa", selection: $keyId) {
                            Text("— chọn khóa —").tag(UUID?.none)
                            ForEach(model.keys) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(editing == nil ? "Host mới" : "Sửa host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") { save() }.disabled(host.isEmpty)
                }
            }
            .onAppear(perform: loadEditing)
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }

    private func loadEditing() {
        guard let e = editing else { return }
        label = e.label; host = e.host; port = e.port; username = e.username
        authType = e.authType; keyId = e.keyId
        if e.authType == .password { password = Keychain.get("host-pw-\(e.id)") ?? "" }
    }

    private func save() {
        var h = editing ?? Host()
        h.label = label; h.host = host; h.port = port; h.username = username
        h.authType = authType; h.keyId = authType == .key ? keyId : nil
        model.upsert(host: h, password: authType == .password ? password : nil)
        dismiss()
    }
}
