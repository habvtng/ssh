// Model dữ liệu: host, khóa SSH, mục file. Credential KHÔNG nằm ở đây —
// mật khẩu/private key lưu trong Keychain (xem Keychain.swift), model chỉ giữ metadata.
import Foundation

enum AuthType: String, Codable, CaseIterable, Identifiable {
    case password
    case key
    var id: String { rawValue }
    var label: String { self == .password ? "Mật khẩu" : "SSH key" }
}

struct Host: Identifiable, Codable, Hashable {
    var id = UUID()
    var label: String = ""
    var host: String = ""
    var port: Int = 22
    var username: String = "root"
    var authType: AuthType = .password
    var keyId: UUID? = nil // dùng khi authType == .key
}

struct SSHKey: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
}

// Một mục trong thư mục SFTP.
struct FileEntry: Identifiable, Hashable {
    var name: String
    var isDir: Bool
    var isSymlink: Bool
    var size: UInt64?
    var id: String { name }
    var icon: String { isDir ? "folder.fill" : (isSymlink ? "arrow.up.right" : "doc") }
}

// Cấu hình kết nối đã giải mã (Sendable để truyền vào actor SSHManager).
struct ConnectionConfig: Sendable, Identifiable {
    var id: UUID
    var host: String
    var port: Int
    var username: String
    var password: String?
    var privateKeyPEM: String?
    var passphrase: String?
}

// Tiện ích đường dẫn kiểu unix.
enum PathUtil {
    static func join(_ base: String, _ name: String) -> String {
        if base.isEmpty || base == "/" { return "/" + name }
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }
    static func parent(_ path: String) -> String {
        if path == "/" || path.isEmpty { return "/" }
        var p = path
        if p.hasSuffix("/") { p.removeLast() }
        guard let idx = p.lastIndex(of: "/") else { return "/" }
        let parent = String(p[..<idx])
        return parent.isEmpty ? "/" : parent
    }
}

func formatSize(_ n: UInt64?) -> String {
    guard let n else { return "" }
    let units = ["B", "K", "M", "G", "T"]
    var x = Double(n); var i = 0
    while x >= 1024 && i < units.count - 1 { x /= 1024; i += 1 }
    return i == 0 ? "\(Int(x))\(units[i])" : String(format: "%.1f%@", x, units[i])
}
