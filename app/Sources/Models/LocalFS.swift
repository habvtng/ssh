// Nguồn của một khung duyệt file + truy cập tệp trên máy (khung "Máy này" ở màn 2 Server).
// App chạy sandbox nên chỉ đọc/ghi được bên trong thư mục người dùng đã tự chọn
// (security-scoped URL); vì vậy khung local luôn có một "thư mục gốc" và không đi lên trên nó.
import Foundation

// Khung file lấy dữ liệu từ đâu: chưa chọn / máy này / một host SSH.
enum PaneSource: Codable, Hashable {
    case unset
    case local
    case host(UUID)

    var hostId: UUID? { if case .host(let id) = self { return id } else { return nil } }
    var isLocal: Bool { if case .local = self { return true } else { return false } }
}

struct LocalFSError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum LocalFS {
    private static let fm = FileManager.default

    static func list(_ path: String) throws -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let items = try fm.contentsOfDirectory(at: URL(fileURLWithPath: path),
                                               includingPropertiesForKeys: keys,
                                               options: [])
        var out: [FileEntry] = []
        for u in items {
            let v = try? u.resourceValues(forKeys: Set(keys))
            out.append(FileEntry(name: u.lastPathComponent,
                                 isDir: v?.isDirectory ?? false,
                                 isSymlink: v?.isSymbolicLink ?? false,
                                 size: (v?.fileSize).map { UInt64($0) }))
        }
        out.sort { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
        return out
    }

    static func isDir(_ path: String) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }
    static func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }

    static func makeDir(_ path: String) throws {
        guard !exists(path) else { throw LocalFSError(message: "\"\((path as NSString).lastPathComponent)\" đã tồn tại.") }
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    static func makeFile(_ path: String) throws {
        guard !exists(path) else { throw LocalFSError(message: "\"\((path as NSString).lastPathComponent)\" đã tồn tại.") }
        guard fm.createFile(atPath: path, contents: Data()) else {
            throw LocalFSError(message: "Không tạo được tệp (thiếu quyền ghi?).")
        }
    }
    static func move(from: String, to: String) throws {
        guard !exists(to) else { throw LocalFSError(message: "\"\((to as NSString).lastPathComponent)\" đã tồn tại.") }
        try fm.moveItem(atPath: from, toPath: to)
    }
    static func delete(_ path: String) throws { try fm.removeItem(atPath: path) }

    static func read(_ path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
    static func write(_ data: Data, to path: String) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // Dung lượng của một tệp, hoặc tổng dung lượng cả cây thư mục (mẫu số cho thanh tiến độ).
    static func totalSize(of path: String) -> Int {
        if !isDir(path) {
            let attrs = try? fm.attributesOfItem(atPath: path)
            return (attrs?[.size] as? NSNumber)?.intValue ?? 0
        }
        var total = 0
        var stack = [path]
        while let d = stack.popLast() {
            for n in (try? fm.contentsOfDirectory(atPath: d)) ?? [] {
                let full = PathUtil.join(d, n)
                if isDir(full) { stack.append(full) } else { total += totalSize(of: full) }
            }
        }
        return total
    }

    // Copy tệp/thư mục (đệ quy) trong cùng máy, có báo tiến độ theo byte.
    static func copyTree(from src: String, to dst: String,
                         onProgress: (Int, Int) -> Void) throws -> (files: Int, bytes: Int) {
        guard !exists(dst) else { throw LocalFSError(message: "\"\((dst as NSString).lastPathComponent)\" đã tồn tại ở thư mục đích.") }
        let total = totalSize(of: src)
        onProgress(0, total)
        var files = 0, bytes = 0
        var stack: [(String, String)] = [(src, dst)]
        while let (s, d) = stack.popLast() {
            if isDir(s) {
                try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
                for n in try fm.contentsOfDirectory(atPath: s) {
                    stack.append((PathUtil.join(s, n), PathUtil.join(d, n)))
                }
            } else {
                try fm.copyItem(atPath: s, toPath: d)
                files += 1
                bytes += totalSize(of: d)
                onProgress(bytes, Swift.max(total, bytes))
            }
        }
        return (files, bytes)
    }

    // Đường dẫn có nằm trong thư mục gốc đã được cấp quyền không (chặn đi lên trên gốc).
    static func isInside(_ path: String, root: String) -> Bool {
        let p = (path as NSString).standardizingPath
        let r = (root as NSString).standardizingPath
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
}

// Nhớ thư mục gốc local đã chọn giữa các lần mở app (bookmark có security scope).
enum LocalRootStore {
    private static let key = "localRootBookmark"

    static func save(_ url: URL) {
        #if os(macOS)
        let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let data = try? url.bookmarkData()
        #endif
        if let data { UserDefaults.standard.set(data, forKey: key) }
    }

    static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        #if os(macOS)
        let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try? URL(resolvingBookmarkData: data, relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        guard let url, !stale else { return nil }
        return url
    }
}
