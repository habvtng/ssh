// Quản lý kết nối SSH/SFTP bằng Citadel — chạy thẳng trên thiết bị, không cần backend.
// Cache client theo host.id để tái dùng cho terminal + SFTP + transfer.
import Foundation
import Citadel
import Crypto
import NIOCore

// Lỗi kết nối có thông điệp tiếng Việt rõ ràng cho UI.
struct SSHFriendlyError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor SSHManager {
    private var clients: [UUID: SSHClient] = [:]

    // Kích thước chunk khi tải lên/tải về/copy — đủ lớn để nhanh, đủ nhỏ để báo tiến độ mượt.
    private static let chunkSize = 1 << 18  // 256 KB

    // Lấy (hoặc tạo) client cho một cấu hình.
    func connect(_ cfg: ConnectionConfig) async throws -> SSHClient {
        if let c = clients[cfg.id], c.isConnected { return c }
        let method = try Self.auth(cfg)
        do {
            let client = try await SSHClient.connect(
                host: cfg.host,
                port: cfg.port,
                authenticationMethod: method,
                hostKeyValidator: .acceptAnything(), // TOFU bỏ qua — demo; prod nên verify known_hosts
                reconnect: .never
            )
            clients[cfg.id] = client
            return client
        } catch {
            throw SSHFriendlyError(message: Self.describe(error, cfg: cfg))
        }
    }

    // Dịch lỗi Citadel/NIO sang thông điệp dễ hiểu.
    private static func describe(_ error: Error, cfg: ConnectionConfig) -> String {
        if let e = error as? SSHClientError {
            switch e {
            case .allAuthenticationOptionsFailed:
                let kind = (cfg.privateKeyPEM?.isEmpty == false) ? "SSH key" : "mật khẩu"
                return "Xác thực thất bại: server từ chối \(kind). Kiểm tra lại username (\(cfg.username)) và \(kind). "
                    + "Nếu server tắt đăng nhập mật khẩu hoặc chỉ dùng keyboard-interactive thì phải dùng SSH key."
            case .unsupportedPasswordAuthentication:
                return "Server không bật đăng nhập bằng mật khẩu (PasswordAuthentication no). Hãy dùng SSH key."
            case .unsupportedPrivateKeyAuthentication:
                return "Server không chấp nhận đăng nhập bằng public key này."
            case .unsupportedHostBasedAuthentication:
                return "Host-based authentication không được hỗ trợ."
            case .channelCreationFailed:
                return "Kết nối được nhưng không mở được kênh SSH."
            }
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain || ns.domain == NSURLErrorDomain {
            return "Không kết nối được tới \(cfg.host):\(cfg.port) — kiểm tra địa chỉ/port/mạng. (\(error.localizedDescription))"
        }
        return error.localizedDescription
    }

    func disconnect(_ id: UUID) async {
        if let c = clients[id] { try? await c.close() }
        clients[id] = nil
    }

    // Dựng phương thức xác thực: password, hoặc private key (thử ed25519 trước, rồi RSA).
    private static func auth(_ cfg: ConnectionConfig) throws -> SSHAuthenticationMethod {
        if let pem = cfg.privateKeyPEM, !pem.isEmpty {
            let decrypt = cfg.passphrase.flatMap { $0.isEmpty ? nil : $0.data(using: .utf8) }
            if let ed = try? Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: decrypt) {
                return .ed25519(username: cfg.username, privateKey: ed)
            }
            do {
                let rsa = try Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: decrypt)
                return .rsa(username: cfg.username, privateKey: rsa)
            } catch {
                throw SSHFriendlyError(message: "Không đọc được private key (sai định dạng hoặc sai passphrase). "
                    + "Hỗ trợ khóa OpenSSH ed25519/RSA.")
            }
        }
        guard let pw = cfg.password, !pw.isEmpty else {
            throw SSHFriendlyError(message: "Thiếu mật khẩu/khóa cho host này. Mở lại host và nhập credential, rồi Lưu.")
        }
        return .passwordBased(username: cfg.username, password: pw)
    }

    // --- SFTP ---

    // Chuẩn hóa đường dẫn về tuyệt đối (xử lý "." → home, "..").
    func realPath(_ cfg: ConnectionConfig, _ path: String) async throws -> String {
        let client = try await connect(cfg)
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        return try await sftp.getRealPath(atPath: path)
    }

    func list(_ cfg: ConnectionConfig, path: String) async throws -> [FileEntry] {
        let client = try await connect(cfg)
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        let names = try await sftp.listDirectory(atPath: path)
        var out: [FileEntry] = []
        for name in names {
            for c in name.components {
                if c.filename == "." || c.filename == ".." { continue }
                let perm = c.attributes.permissions ?? 0
                out.append(FileEntry(
                    name: c.filename,
                    isDir: (perm & 0o170000) == 0o040000,
                    isSymlink: (perm & 0o170000) == 0o120000,
                    size: c.attributes.size
                ))
            }
        }
        out.sort { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
        return out
    }

    // Đọc file (giới hạn để xem nhanh).
    func read(_ cfg: ConnectionConfig, path: String, max: Int = 1 << 20) async throws -> Data {
        let client = try await connect(cfg)
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        var buf = try await sftp.withFile(filePath: path, flags: .read) { file in
            try await file.readAll()
        }
        let bytes = buf.readBytes(length: Swift.min(buf.readableBytes, max)) ?? []
        return Data(bytes)
    }

    // Chạy một lệnh shell, trả stdout dạng chuỗi (dùng cho Metrics).
    func run(_ cfg: ConnectionConfig, command: String) async throws -> String {
        let client = try await connect(cfg)
        let buf = try await client.executeCommand(command)
        return String(buffer: buf)
    }

    // --- Đọc / ghi nội dung tệp (để sửa) ---

    // Đọc tệp để sửa. Từ chối tệp quá lớn để tránh nạp cả file khổng lồ vào RAM.
    func readFile(_ cfg: ConnectionConfig, path: String, max: Int = 1 << 20) async throws -> Data {
        let client = try await connect(cfg)
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        if let size = try? await sftp.getAttributes(at: path).size, Int(size) > max {
            throw SSHFriendlyError(message: "Tệp quá lớn để sửa (\(formatSize(size))). Chỉ hỗ trợ tệp ≤ \(formatSize(UInt64(max))).")
        }
        var buf = try await sftp.withFile(filePath: path, flags: .read) { f in
            try await f.readAll()
        }
        return Data(buf.readBytes(length: buf.readableBytes) ?? [])
    }

    func writeFile(_ cfg: ConnectionConfig, path: String, data: Data) async throws {
        let client = try await connect(cfg)
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { f in
            try await f.write(ByteBuffer(bytes: Array(data)), at: 0)
        }
    }

    // Tải dữ liệu từ máy lên server theo từng chunk, gọi onProgress(đã ghi, tổng) để báo tiến độ.
    func upload(_ cfg: ConnectionConfig, path: String, data: Data,
                onProgress: @escaping @Sendable (Int, Int) -> Void) async throws {
        let client = try await connect(cfg)
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        let total = data.count
        onProgress(0, total)
        try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { f in
            if total == 0 { try await f.write(ByteBuffer()); return }
            var offset = 0
            while offset < total {
                let end = Swift.min(offset + Self.chunkSize, total)
                try await f.write(ByteBuffer(bytes: data[offset..<end]), at: UInt64(offset))
                offset = end
                onProgress(offset, total)
            }
        }
    }

    // Tải toàn bộ một tệp về (không giới hạn dung lượng như readFile dùng để sửa).
    func downloadAll(_ cfg: ConnectionConfig, path: String) async throws -> Data {
        let client = try await connect(cfg)
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        var buf = try await sftp.withFile(filePath: path, flags: .read) { f in
            try await f.readAll()
        }
        return Data(buf.readBytes(length: buf.readableBytes) ?? [])
    }

    // Tải tệp về theo từng chunk, gọi onProgress(đã tải, tổng) để báo tiến độ.
    // total = 0 nếu không lấy được kích thước trước; khi đó mẫu số được nâng dần theo số byte đã đọc.
    func download(_ cfg: ConnectionConfig, path: String,
                  onProgress: @escaping @Sendable (Int, Int) -> Void) async throws -> Data {
        let client = try await connect(cfg)
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        let total = Int((try? await sftp.getAttributes(at: path).size) ?? 0)
        onProgress(0, total)
        var out = Data()
        if total > 0 { out.reserveCapacity(total) }
        try await sftp.withFile(filePath: path, flags: .read) { f in
            var offset: UInt64 = 0
            while true {
                var buf = try await f.read(from: offset, length: UInt32(Self.chunkSize))
                let n = buf.readableBytes
                if n == 0 { break }
                if let bytes = buf.readBytes(length: n) { out.append(contentsOf: bytes) }
                offset += UInt64(n)
                onProgress(Int(offset), Swift.max(total, Int(offset)))
            }
        }
        return out
    }

    // --- Tạo / sửa / xóa ---

    func makeDir(_ cfg: ConnectionConfig, path: String) async throws {
        let client = try await connect(cfg)
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        try await sftp.createDirectory(atPath: path)
    }

    func makeFile(_ cfg: ConnectionConfig, path: String) async throws {
        let client = try await connect(cfg)
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { f in
            try await f.write(ByteBuffer())
        }
    }

    func rename(_ cfg: ConnectionConfig, from: String, to: String) async throws {
        let client = try await connect(cfg)
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        try await sftp.rename(at: from, to: to)
    }

    // Xóa file, hoặc thư mục (đệ quy: xóa hết nội dung rồi rmdir từ trong ra ngoài).
    func delete(_ cfg: ConnectionConfig, path: String) async throws {
        let client = try await connect(cfg)
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        let attrs = try await sftp.getAttributes(at: path)
        let isDir = ((attrs.permissions ?? 0) & 0o170000) == 0o040000
        if !isDir {
            try await sftp.remove(at: path)
            return
        }
        // Duyệt pre-order, xóa file ngay, gom thư mục để rmdir theo thứ tự ngược (sâu nhất trước).
        var dirs: [String] = []
        var stack = [path]
        while let d = stack.popLast() {
            dirs.append(d)
            for n in try await sftp.listDirectory(atPath: d) {
                for c in n.components where c.filename != "." && c.filename != ".." {
                    let full = PathUtil.join(d, c.filename)
                    if ((c.attributes.permissions ?? 0) & 0o170000) == 0o040000 {
                        stack.append(full)
                    } else {
                        try await sftp.remove(at: full)
                    }
                }
            }
        }
        for d in dirs.reversed() { try await sftp.rmdir(at: d) }
    }

    // Copy file/thư mục (đệ quy) giữa hai host. Dữ liệu đi qua thiết bị này làm cầu nối.
    func transfer(from src: ConnectionConfig, srcPath: String,
                  to dst: ConnectionConfig, dstDir: String, name: String,
                  onProgress: @escaping @Sendable (Int, Int) -> Void) async throws -> (files: Int, bytes: Int) {
        let srcClient = try await connect(src)
        let dstClient = try await connect(dst)
        let srcSFTP = try await srcClient.openSFTP()
        let dstSFTP = try await dstClient.openSFTP()
        defer { Task { try? await srcSFTP.close(); try? await dstSFTP.close() } }

        // Quét trước cây nguồn để biết tổng dung lượng (mẫu số cho tiến độ).
        var total = 0
        var scan = [srcPath]
        while let sp = scan.popLast() {
            let attrs = try await srcSFTP.getAttributes(at: sp)
            let isDir = ((attrs.permissions ?? 0) & 0o170000) == 0o040000
            if isDir {
                for n in try await srcSFTP.listDirectory(atPath: sp) {
                    for c in n.components where c.filename != "." && c.filename != ".." {
                        scan.append(PathUtil.join(sp, c.filename))
                    }
                }
            } else {
                total += Int(attrs.size ?? 0)
            }
        }
        onProgress(0, total)

        var files = 0, bytes = 0
        var stack: [(String, String)] = [(srcPath, PathUtil.join(dstDir, name))]
        while let (sp, dp) = stack.popLast() {
            let attrs = try await srcSFTP.getAttributes(at: sp)
            let perm = attrs.permissions ?? 0
            let isDir = (perm & 0o170000) == 0o040000
            if isDir {
                _ = try? await dstSFTP.createDirectory(atPath: dp)
                let names = try await srcSFTP.listDirectory(atPath: sp)
                for n in names {
                    for c in n.components where c.filename != "." && c.filename != ".." {
                        stack.append((PathUtil.join(sp, c.filename), PathUtil.join(dp, c.filename)))
                    }
                }
            } else {
                // Đọc–ghi theo chunk để file lớn cũng cập nhật tiến độ từng phần.
                try await srcSFTP.withFile(filePath: sp, flags: .read) { rf in
                    try await dstSFTP.withFile(filePath: dp, flags: [.write, .create, .truncate]) { wf in
                        var offset: UInt64 = 0
                        while true {
                            let chunk = try await rf.read(from: offset, length: UInt32(Self.chunkSize))
                            let n = chunk.readableBytes
                            if n == 0 { break }
                            try await wf.write(chunk, at: offset)
                            offset += UInt64(n)
                            bytes += n
                            onProgress(bytes, Swift.max(total, bytes))
                        }
                    }
                }
                files += 1
            }
        }
        return (files, bytes)
    }
}
