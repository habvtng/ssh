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

// Tiến độ một lần tải lên / tải về / copy — để hiện % + thanh tiến trình + tốc độ.
struct TransferProgress {
    enum Kind { case upload, download, copy }
    var kind: Kind
    var name: String
    var done: Int            // số byte đã xong
    var total: Int           // tổng byte (0 nếu chưa biết)
    var startedAt = Date()

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Swift.min(1, Double(done) / Double(total))
    }
    var percent: Int { Int((fraction * 100).rounded()) }
    var verb: String {
        switch kind {
        case .upload: return "Đang tải lên"
        case .download: return "Đang tải về"
        case .copy: return "Đang copy"
        }
    }
    // Tốc độ trung bình (B/s) tính từ lúc bắt đầu; 0 nếu quá sớm để ước lượng.
    var speed: Double {
        let dt = Date().timeIntervalSince(startedAt)
        return dt > 0.3 ? Double(done) / dt : 0
    }
    // Dòng chi tiết: "12.3M / 50.0M · 8.4M/s"
    var detail: String {
        var parts: [String] = []
        parts.append(total > 0
            ? "\(formatSize(UInt64(done))) / \(formatSize(UInt64(total)))"
            : formatSize(UInt64(done)))
        if speed > 0 { parts.append("\(formatSize(UInt64(speed)))/s") }
        return parts.joined(separator: " · ")
    }
}

func formatSize(_ n: UInt64?) -> String {
    guard let n else { return "" }
    let units = ["B", "K", "M", "G", "T"]
    var x = Double(n); var i = 0
    while x >= 1024 && i < units.count - 1 { x /= 1024; i += 1 }
    return i == 0 ? "\(Int(x))\(units[i])" : String(format: "%.1f%@", x, units[i])
}
