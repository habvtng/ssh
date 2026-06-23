// Trạng thái app: danh sách host/key + persistence (UserDefaults cho metadata,
// Keychain cho credential). Giữ một SSHManager dùng chung.
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var hosts: [Host] = []
    var keys: [SSHKey] = []
    let ssh = SSHManager()

    init() { load() }

    private func load() {
        if let d = UserDefaults.standard.data(forKey: "hosts"),
           let v = try? JSONDecoder().decode([Host].self, from: d) { hosts = v }
        if let d = UserDefaults.standard.data(forKey: "keys"),
           let v = try? JSONDecoder().decode([SSHKey].self, from: d) { keys = v }
    }
    private func saveHosts() {
        if let d = try? JSONEncoder().encode(hosts) { UserDefaults.standard.set(d, forKey: "hosts") }
    }
    private func saveKeys() {
        if let d = try? JSONEncoder().encode(keys) { UserDefaults.standard.set(d, forKey: "keys") }
    }

    // --- Hosts ---
    func upsert(host: Host, password: String?) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) { hosts[i] = host }
        else { hosts.append(host) }
        if host.authType == .password { Keychain.set(password, for: "host-pw-\(host.id)") }
        saveHosts()
    }
    func delete(host: Host) {
        hosts.removeAll { $0.id == host.id }
        Keychain.delete("host-pw-\(host.id)")
        Task { await ssh.disconnect(host.id) }
        saveHosts()
    }

    // --- Keys ---
    func upsert(key: SSHKey, privateKey: String?, passphrase: String?) {
        if let i = keys.firstIndex(where: { $0.id == key.id }) { keys[i] = key }
        else { keys.append(key) }
        if let privateKey, !privateKey.isEmpty { Keychain.set(privateKey, for: "key-priv-\(key.id)") }
        Keychain.set(passphrase, for: "key-pass-\(key.id)")
        saveKeys()
    }
    func delete(key: SSHKey) {
        keys.removeAll { $0.id == key.id }
        Keychain.delete("key-priv-\(key.id)")
        Keychain.delete("key-pass-\(key.id)")
        saveKeys()
    }

    func host(id: UUID?) -> Host? { hosts.first { $0.id == id } }

    // Dựng cấu hình kết nối (đọc credential từ Keychain).
    func config(for host: Host) -> ConnectionConfig {
        var pw: String?, pk: String?, pass: String?
        if host.authType == .password {
            pw = Keychain.get("host-pw-\(host.id)")
        } else if let kid = host.keyId {
            pk = Keychain.get("key-priv-\(kid)")
            pass = Keychain.get("key-pass-\(kid)")
        }
        return ConnectionConfig(id: host.id, host: host.host, port: host.port,
                                username: host.username, password: pw,
                                privateKeyPEM: pk, passphrase: pass)
    }
    func config(forHostId id: UUID) -> ConnectionConfig? {
        host(id: id).map { config(for: $0) }
    }
}
