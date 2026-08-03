// Khung duyệt file tái dùng + kiểu kéo–thả. Dùng cho cả màn 2 Server lẫn tab SFTP của host.
// Mỗi khung có thể trỏ tới một server (SFTP) hoặc "Máy này" (thư mục local đã được cấp quyền),
// nên kéo–thả giữa 2 khung làm được: local → server (upload), server → local (download),
// server → server (copy) và local → local (copy trong máy).
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    // UTType riêng cho kéo–thả nội bộ app (macOS List + .json Transferable hay bị nuốt drop).
    static let sftpRef = UTType(exportedAs: "vn.tre360.ssh.sftp-ref")
}

// Dữ liệu kéo–thả: nguồn (server hoặc máy này) + đường dẫn tuyệt đối.
struct SFTPRef: Codable, Transferable {
    var source: PaneSource
    var path: String
    var name: String
    var isDir: Bool
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sftpRef)
    }

    // Pasteboard tường minh — ổn định hơn .draggable/.dropDestination trên macOS List.
    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        guard let data = try? JSONEncoder().encode(self) else { return provider }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.sftpRef.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func load(from providers: [NSItemProvider]) async -> [SFTPRef] {
        var refs: [SFTPRef] = []
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.sftpRef.identifier) else { continue }
            let data: Data? = await withCheckedContinuation { cont in
                provider.loadDataRepresentation(forTypeIdentifier: UTType.sftpRef.identifier) { data, _ in
                    cont.resume(returning: data)
                }
            }
            if let data, let ref = try? JSONDecoder().decode(SFTPRef.self, from: data) {
                refs.append(ref)
            }
        }
        return refs
    }

    // Tệp/thư mục kéo thẳng từ Finder (không phải kéo giữa 2 khung của app).
    static func loadFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { cont in
                _ = provider.loadObject(ofClass: URL.self) { u, _ in cont.resume(returning: u) }
            }
            if let url { urls.append(url) }
        }
        return urls
    }
}

@MainActor
@Observable
final class PaneModel {
    private var app: AppModel?
    var source: PaneSource = .unset
    var path: String = ""
    var entries: [FileEntry] = []
    var status: String = ""
    var busy = false
    var transfer: TransferProgress?   // tiến độ tải lên/tải về/copy đang chạy (nil khi rảnh)
    var localRoot: URL?               // thư mục gốc trên máy (sandbox: chỉ đi lại bên trong nó)
    @ObservationIgnored private var scoped: URL?   // URL đang giữ security scope

    var hostId: UUID? { source.hostId }
    var isLocal: Bool { source.isLocal }
    var localRootPath: String { localRoot?.path ?? "" }
    // Khung đã sẵn sàng làm việc chưa (đã chọn server, hoặc đã chọn thư mục trên máy).
    var isReady: Bool { hostId != nil || (isLocal && localRoot != nil) }

    deinit { scoped?.stopAccessingSecurityScopedResource() }

    func attach(_ model: AppModel) { if app == nil { app = model } }

    func selectSource(_ s: PaneSource) {
        guard s != source else { return }
        source = s
        entries = []; path = ""; status = ""; moveSource = nil
        switch s {
        case .unset:
            break
        case .host:
            Task { await load(".") }
        case .local:
            if localRoot == nil, let saved = LocalRootStore.restore() {
                setLocalRoot(saved)
            } else if let root = localRoot {
                Task { await load(root.path) }
            } else {
                status = "Chọn thư mục trên máy để bắt đầu."
            }
        }
    }
    // Giữ lại cho tab SFTP của một host (chọn sẵn host đó).
    func selectHost(_ id: UUID?) { selectSource(id.map { PaneSource.host($0) } ?? .unset) }

    // Nhận thư mục người dùng vừa chọn: giữ security scope để đọc/ghi cả cây bên trong.
    func setLocalRoot(_ url: URL) {
        scoped?.stopAccessingSecurityScopedResource()
        scoped = url.startAccessingSecurityScopedResource() ? url : nil
        localRoot = url
        source = .local
        moveSource = nil
        LocalRootStore.save(url)
        Task { await load(url.path) }
    }

    func reload() { Task { await load(path.isEmpty ? "." : path) } }
    func up() {
        let parent = PathUtil.parent(path)
        if isLocal {
            guard let root = localRoot, LocalFS.isInside(parent, root: root.path) else {
                status = "Đã ở thư mục gốc đã chọn — bấm 📁 để chọn thư mục khác."
                return
            }
        }
        Task { await load(parent) }
    }
    func open(_ entry: FileEntry) {
        guard entry.isDir else { return }
        Task { await load(PathUtil.join(path, entry.name)) }
    }

    func load(_ p: String) async {
        busy = true; status = "đang tải…"
        do {
            switch source {
            case .unset:
                entries = []; path = ""; status = ""
            case .local:
                guard let root = localRoot else {
                    entries = []; status = "Chọn thư mục trên máy để bắt đầu."; busy = false; return
                }
                var target = (p.isEmpty || p == ".") ? root.path : p
                if !LocalFS.isInside(target, root: root.path) { target = root.path }
                entries = try LocalFS.list(target); path = target; status = ""
            case .host(let id):
                guard let app, let cfg = app.config(forHostId: id) else { busy = false; return }
                let real = try await app.ssh.realPath(cfg, p)
                let items = try await app.ssh.list(cfg, path: real)
                path = real; entries = items; status = ""
            }
        } catch {
            status = "Lỗi: \(error.localizedDescription)"
        }
        busy = false
    }

    // --- Tạo / sửa / xóa ---
    func makeDir(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
        let dst = PathUtil.join(path, n)
        perform("✓ Đã tạo thư mục \"\(n)\"") {
            try LocalFS.makeDir(dst)
        } remote: { app, cfg in
            try await app.ssh.makeDir(cfg, path: dst)
        }
    }
    func makeFile(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
        let dst = PathUtil.join(path, n)
        perform("✓ Đã tạo tệp \"\(n)\"") {
            try LocalFS.makeFile(dst)
        } remote: { app, cfg in
            try await app.ssh.makeFile(cfg, path: dst)
        }
    }
    func rename(_ entry: FileEntry, to newName: String) {
        let n = newName.trimmingCharacters(in: .whitespaces); guard !n.isEmpty, n != entry.name else { return }
        let from = PathUtil.join(path, entry.name), to = PathUtil.join(path, n)
        perform("✓ Đã đổi tên thành \"\(n)\"") {
            try LocalFS.move(from: from, to: to)
        } remote: { app, cfg in
            try await app.ssh.rename(cfg, from: from, to: to)
        }
    }
    func remove(_ entry: FileEntry) {
        let target = PathUtil.join(path, entry.name)
        perform("✓ Đã xóa \"\(entry.name)\"") {
            try LocalFS.delete(target)
        } remote: { app, cfg in
            try await app.ssh.delete(cfg, path: target)
        }
    }

    // Di chuyển trong cùng nguồn: cắt một mục rồi dán vào thư mục đang mở.
    var moveSource: (path: String, name: String)?
    func cut(_ entry: FileEntry) {
        moveSource = (PathUtil.join(path, entry.name), entry.name)
        status = "✂️ Đã cắt \"\(entry.name)\" — mở thư mục đích rồi bấm Dán."
    }
    func paste() {
        guard let src = moveSource else { return }
        let dest = PathUtil.join(path, src.name)
        if dest == src.path { status = "Đã ở đúng thư mục này."; return }
        perform("✓ Đã di chuyển \"\(src.name)\"") {
            try LocalFS.move(from: src.path, to: dest)
        } remote: { app, cfg in
            try await app.ssh.rename(cfg, from: src.path, to: dest)
        }
        moveSource = nil
    }

    // Cập nhật tiến độ (gọi từ background actor → nhảy về MainActor).
    private func updateTransfer(done: Int, total: Int) {
        transfer?.done = done
        transfer?.total = total
    }

    // --- Tải lên / tải về ---
    // Đưa dữ liệu từ tệp người dùng chọn vào thư mục đang mở (server: upload; máy này: ghi thẳng).
    func upload(name: String, data: Data) {
        let n = name.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
        let dst = PathUtil.join(path, n)
        if isLocal {
            perform("✓ Đã chép \"\(n)\" vào thư mục này") {
                try LocalFS.write(data, to: dst)
            } remote: { _, _ in }
            return
        }
        guard let app, let id = hostId, let cfg = app.config(forHostId: id) else {
            status = "Chọn server trước."; return
        }
        Task {
            busy = true
            transfer = TransferProgress(kind: .upload, name: n, done: 0, total: data.count)
            status = "⏳ Đang tải lên \"\(n)\"…"
            do {
                try await app.ssh.upload(cfg, path: dst, data: data) { done, tot in
                    Task { @MainActor in self.updateTransfer(done: done, total: tot) }
                }
                status = "✓ Đã tải lên \"\(n)\" (\(formatSize(UInt64(data.count))))"
                await load(path.isEmpty ? "." : path)
            } catch {
                status = "Lỗi: \(error.localizedDescription)"
            }
            transfer = nil; busy = false
        }
    }

    // Download: lấy toàn bộ nội dung tệp về để người dùng chọn nơi lưu, có báo tiến độ.
    func download(_ entry: FileEntry) async -> Data? {
        if isLocal {
            do { return try LocalFS.read(PathUtil.join(path, entry.name)) }
            catch { status = "Lỗi đọc tệp: \(error.localizedDescription)"; return nil }
        }
        guard let app, let id = hostId, let cfg = app.config(forHostId: id) else {
            status = "Chọn server trước."; return nil
        }
        busy = true
        transfer = TransferProgress(kind: .download, name: entry.name, done: 0, total: Int(entry.size ?? 0))
        status = "⏳ Đang tải \"\(entry.name)\"…"
        defer { busy = false; transfer = nil }
        do {
            let data = try await app.ssh.download(cfg, path: PathUtil.join(path, entry.name)) { done, tot in
                Task { @MainActor in self.updateTransfer(done: done, total: tot) }
            }
            status = "✓ Đã tải \"\(entry.name)\" (\(formatSize(UInt64(data.count)))) — chọn nơi lưu."
            return data
        } catch {
            status = "Lỗi tải: \(error.localizedDescription)"; return nil
        }
    }

    // Thao tác tạo/sửa/xóa: cùng một nút, chạy nhánh local hay nhánh SFTP tùy nguồn của khung.
    private func perform(_ okMsg: String,
                         local: @escaping () throws -> Void,
                         remote: @escaping (AppModel, ConnectionConfig) async throws -> Void) {
        Task {
            busy = true; status = "đang xử lý…"
            do {
                switch source {
                case .unset:
                    throw LocalFSError(message: "Chọn nguồn cho khung này trước.")
                case .local:
                    guard localRoot != nil else { throw LocalFSError(message: "Chọn thư mục trên máy trước.") }
                    try local()
                case .host(let id):
                    guard let app, let cfg = app.config(forHostId: id) else {
                        throw LocalFSError(message: "Không tìm thấy server.")
                    }
                    try await remote(app, cfg)
                }
                status = okMsg
                await load(path.isEmpty ? "." : path)
            } catch {
                status = "Lỗi: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    // Nhận một mục được thả vào: copy từ nguồn (server khác hoặc máy này) sang khung này.
    func receive(_ ref: SFTPRef, intoFolder folder: String?) {
        guard let app else { return }
        let dstDir = folder ?? path
        switch (source, ref.source) {
        case (.unset, _):
            status = "Chọn nguồn cho khung đích trước."
        case (_, .unset):
            status = "Nguồn kéo không hợp lệ."

        // Máy này → server: upload tệp/thư mục.
        case (.host(let dstId), .local):
            guard let dstCfg = app.config(forHostId: dstId) else { return }
            let src = ref.path
            run(.upload, ref.name) {
                try await app.ssh.uploadTree(dstCfg, localPath: src, dstDir: dstDir, name: ref.name) { d, t in
                    Task { @MainActor in self.updateTransfer(done: d, total: t) }
                }
            }

        // Server → máy này: tải tệp/thư mục về thư mục đang mở.
        case (.local, .host(let srcId)):
            guard localRoot != nil else { status = "Chọn thư mục trên máy trước."; return }
            guard let srcCfg = app.config(forHostId: srcId) else { return }
            let src = ref.path
            run(.download, ref.name) {
                try await app.ssh.downloadTree(srcCfg, srcPath: src, dstDir: dstDir, name: ref.name) { d, t in
                    Task { @MainActor in self.updateTransfer(done: d, total: t) }
                }
            }

        // Máy này → máy này: copy trong ổ đĩa.
        case (.local, .local):
            guard localRoot != nil else { status = "Chọn thư mục trên máy trước."; return }
            let src = ref.path
            let dst = PathUtil.join(dstDir, ref.name)
            if LocalFS.isInside(dst, root: src) {
                status = "Không copy được thư mục vào chính nó."
                return
            }
            run(.copy, ref.name) {
                try await Task.detached {
                    try LocalFS.copyTree(from: src, to: dst) { d, t in
                        Task { @MainActor in self.updateTransfer(done: d, total: t) }
                    }
                }.value
            }

        // Server → server: copy qua thiết bị này làm cầu nối (như cũ).
        case (.host(let dstId), .host(let srcId)):
            guard let dstCfg = app.config(forHostId: dstId), let srcCfg = app.config(forHostId: srcId) else { return }
            let src = ref.path
            run(.copy, ref.name) {
                try await app.ssh.transfer(from: srcCfg, srcPath: src, to: dstCfg,
                                           dstDir: dstDir, name: ref.name) { d, t in
                    Task { @MainActor in self.updateTransfer(done: d, total: t) }
                }
            }
        }
    }

    // Nhận tệp/thư mục kéo thẳng từ Finder vào khung này (khung server → upload; khung máy này → copy).
    func receiveLocalURL(_ url: URL, intoFolder folder: String?) {
        let dstDir = folder ?? path
        let name = url.lastPathComponent
        switch source {
        case .unset:
            status = "Chọn nguồn cho khung đích trước."
        case .local:
            guard localRoot != nil else { status = "Chọn thư mục trên máy trước."; return }
            let dst = PathUtil.join(dstDir, name)
            run(.copy, name) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try await Task.detached {
                    try LocalFS.copyTree(from: url.path, to: dst) { d, t in
                        Task { @MainActor in self.updateTransfer(done: d, total: t) }
                    }
                }.value
            }
        case .host(let id):
            guard let app, let cfg = app.config(forHostId: id) else { return }
            run(.upload, name) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try await app.ssh.uploadTree(cfg, localPath: url.path, dstDir: dstDir, name: name) { d, t in
                    Task { @MainActor in self.updateTransfer(done: d, total: t) }
                }
            }
        }
    }

    // Chạy một lần truyền (upload/download/copy) kèm thanh tiến độ + thông báo kết quả.
    private func run(_ kind: TransferProgress.Kind, _ name: String,
                     _ work: @escaping () async throws -> (files: Int, bytes: Int)) {
        Task {
            busy = true
            let p = TransferProgress(kind: kind, name: name, done: 0, total: 0)
            transfer = p
            status = "⏳ \(p.verb) \"\(name)\"…"
            do {
                let r = try await work()
                status = "✓ Xong \"\(name)\" — \(r.files) file, \(formatSize(UInt64(r.bytes)))"
                await load(path.isEmpty ? "." : path)
            } catch {
                status = "Lỗi: \(error.localizedDescription)"
            }
            transfer = nil; busy = false
        }
    }
}

struct PaneView: View {
    @Environment(AppModel.self) private var model
    var pane: PaneModel
    var tag: String? = nil          // nhãn "Trái"/"Phải" cho layout iPhone
    var showToolbar = true          // hàng chọn nguồn + nút
    var showBody = true             // breadcrumb + danh sách + trạng thái
    var allowLocal = true           // cho chọn "Máy này" trong danh sách nguồn

    @State private var showNewFolder = false
    @State private var showNewFile = false
    @State private var newName = ""
    @State private var renaming: FileEntry?
    @State private var renameText = ""
    @State private var deleting: FileEntry?
    @State private var editing: FileEntry?
    @State private var showImporter = false
    @State private var showFolderPicker = false
    @State private var exportFile: ExportFile?
    #if os(macOS)
    @State private var paneDropTarget = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            if showToolbar {
                toolbar
                if showBody { Divider() }
            }
            if showBody { bodyView }
        }
        // Đặt ở ngoài cùng để nút "Chọn thư mục trên máy" trong danh sách cũng mở được
        // (layout iPhone có khung chỉ hiện danh sách, không có toolbar).
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): pane.setLocalRoot(url)
            case .failure(let e): pane.status = "Lỗi chọn thư mục: \(e.localizedDescription)"
            }
        }
    }

    // Hàng chọn nguồn (máy này / server) + lên thư mục cha + tải lại.
    @ViewBuilder private var toolbar: some View {
        HStack(spacing: 8) {
            if let tag {
                Text(tag).font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
            }
            Picker("Nguồn", selection: Binding(get: { pane.source }, set: { select($0) })) {
                Text("— chọn nguồn —").tag(PaneSource.unset)
                if allowLocal {
                    Text("💻 Máy này").tag(PaneSource.local)
                }
                ForEach(model.hosts) { h in
                    Text(h.label.isEmpty ? h.host : h.label).tag(PaneSource.host(h.id))
                }
            }
            .labelsHidden()
            Button { pane.up() } label: { Image(systemName: "arrow.up") }
                .disabled(!pane.isReady)
            Button { pane.reload() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(!pane.isReady)
            if pane.moveSource != nil {
                Button { pane.paste() } label: { Image(systemName: "doc.on.clipboard") }
            }
            if pane.isLocal {
                // Sandbox: chỉ vào được thư mục người dùng tự chọn — nút này để chọn/đổi thư mục gốc.
                Button { showFolderPicker = true } label: { Image(systemName: "folder") }
                    .help("Chọn thư mục trên máy")
            } else {
                Button { showImporter = true } label: { Image(systemName: "arrow.up.doc") }
                    .disabled(!pane.isReady)
            }
            Menu {
                Button { newName = ""; showNewFolder = true } label: { Label("Thư mục mới", systemImage: "folder.badge.plus") }
                Button { newName = ""; showNewFile = true } label: { Label("Tệp mới", systemImage: "doc.badge.plus") }
                if pane.isLocal {
                    Button { showFolderPicker = true } label: { Label("Chọn thư mục trên máy", systemImage: "folder") }
                } else {
                    Button { showImporter = true } label: { Label("Tải tệp từ máy lên", systemImage: "arrow.up.doc") }
                }
            } label: { Image(systemName: "plus") }
                .disabled(!pane.isReady)
        }
        .padding(8)
        .alert("Thư mục mới", isPresented: $showNewFolder) {
            TextField("Tên thư mục", text: $newName)
            Button("Tạo") { pane.makeDir(newName); newName = "" }
            Button("Hủy", role: .cancel) { newName = "" }
        }
        .alert("Tệp mới", isPresented: $showNewFile) {
            TextField("Tên tệp", text: $newName)
            Button("Tạo") { pane.makeFile(newName); newName = "" }
            Button("Hủy", role: .cancel) { newName = "" }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        pane.upload(name: url.lastPathComponent, data: data)
                    } else {
                        pane.status = "Không đọc được tệp \"\(url.lastPathComponent)\"."
                    }
                }
            case .failure(let e):
                pane.status = "Lỗi chọn tệp: \(e.localizedDescription)"
            }
        }
    }

    // Chọn nguồn; chọn "Máy này" lần đầu thì mở luôn hộp chọn thư mục.
    private func select(_ s: PaneSource) {
        pane.selectSource(s)
        if s.isLocal && pane.localRoot == nil { showFolderPicker = true }
    }

    // Breadcrumb + danh sách file (vùng kéo–thả) + thanh trạng thái.
    @ViewBuilder private var bodyView: some View {
        VStack(spacing: 0) {
            Text(pane.path.isEmpty ? " " : pane.path)
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
            Divider()

            #if os(macOS)
            macFileList
            #else
            iosFileList
            #endif

            Divider()
            VStack(spacing: 4) {
                if let t = pane.transfer {
                    HStack(spacing: 6) {
                        Text("\(t.verb) \"\(t.name)\"")
                            .font(.caption2).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(t.percent)%")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                    }
                    if t.total > 0 {
                        ProgressView(value: t.fraction).progressViewStyle(.linear)
                    } else {
                        ProgressView().progressViewStyle(.linear)   // chưa biết tổng → chạy không xác định
                    }
                    Text(t.detail)
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 8) {
                        if pane.busy { ProgressView().controlSize(.small) }
                        Text(pane.status.isEmpty ? "Sẵn sàng" : pane.status)
                            .font(.caption2).lineLimit(2)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .alert("Đổi tên", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Tên mới", text: $renameText)
            Button("Lưu") { if let e = renaming { pane.rename(e, to: renameText) }; renaming = nil }
            Button("Hủy", role: .cancel) { renaming = nil }
        }
        .alert("Xóa \"\(deleting?.name ?? "")\"?",
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Xóa", role: .destructive) { if let e = deleting { pane.remove(e) }; deleting = nil }
            Button("Hủy", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting?.isDir == true ? "Thư mục và toàn bộ nội dung bên trong sẽ bị xóa." : "Tệp sẽ bị xóa.")
        }
        .sheet(item: $editing) { entry in
            FileEditorView(source: pane.source, path: PathUtil.join(pane.path, entry.name), name: entry.name) {
                pane.status = "✓ Đã lưu \"\(entry.name)\""
            }
        }
        .fileExporter(isPresented: Binding(get: { exportFile != nil }, set: { if !$0 { exportFile = nil } }),
                      document: exportFile,
                      contentType: exportFile?.contentType ?? .data,
                      defaultFilename: exportFile?.name) { result in
            switch result {
            case .success: pane.status = "✓ Đã lưu về máy."
            case .failure(let e): pane.status = "Lỗi lưu: \(e.localizedDescription)"
            }
        }
    }

    private func startDownload(_ entry: FileEntry) {
        Task {
            if let data = await pane.download(entry) {
                exportFile = ExportFile(data: data, name: entry.name)
            }
        }
    }

    #if os(macOS)
    // macOS: List + Transferable tùy chỉnh hay không nhận drop — dùng ScrollView + onDrag/onDrop.
    @ViewBuilder private var macFileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(pane.entries) { entry in
                    row(entry)
                    Divider()
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(paneDropTarget ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay { fileListPlaceholder }
        .onDrop(of: [UTType.sftpRef, UTType.fileURL], isTargeted: $paneDropTarget) { providers in
            handleDrop(providers, intoFolder: nil)
        }
    }
    #else
    @ViewBuilder private var iosFileList: some View {
        List {
            ForEach(pane.entries) { entry in
                row(entry)
            }
        }
        .listStyle(.plain)
        .frame(maxHeight: .infinity)
        .overlay { fileListPlaceholder }
        .dropDestination(for: SFTPRef.self) { items, _ in
            for it in items { pane.receive(it, intoFolder: nil) }
            return !items.isEmpty
        }
    }
    #endif

    @ViewBuilder private var fileListPlaceholder: some View {
        if pane.isLocal && pane.localRoot == nil {
            Button("Chọn thư mục trên máy") { showFolderPicker = true }
                .font(.caption)
        } else if pane.entries.isEmpty && pane.isReady && !pane.busy {
            Text("(thư mục trống)").font(.caption).foregroundStyle(.secondary)
        } else if !pane.isReady {
            Text("Chọn nguồn").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], intoFolder folder: String?) -> Bool {
        Task {
            let items = await SFTPRef.load(from: providers)
            if !items.isEmpty {
                for it in items { pane.receive(it, intoFolder: folder) }
                return
            }
            // Không phải kéo giữa 2 khung → thử tệp/thư mục kéo từ Finder.
            for url in await SFTPRef.loadFileURLs(from: providers) {
                pane.receiveLocalURL(url, intoFolder: folder)
            }
        }
        return true
    }

    @ViewBuilder
    private func row(_ entry: FileEntry) -> some View {
        let full = PathUtil.join(pane.path, entry.name)
        let ref = SFTPRef(source: pane.source, path: full, name: entry.name, isDir: entry.isDir)
        let content = HStack(spacing: 8) {
            Image(systemName: entry.icon)
                .foregroundStyle(entry.isDir ? Color.accentColor : .secondary)
            Text(entry.name).lineLimit(1)
            Spacer()
            Text(entry.isDir ? "" : formatSize(entry.size))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if entry.isDir { pane.open(entry) } else { editing = entry } }
        .contextMenu {
            if !entry.isDir {
                Button { editing = entry } label: { Label("Sửa nội dung", systemImage: "square.and.pencil") }
                if !pane.isLocal {
                    Button { startDownload(entry) } label: { Label("Tải về máy", systemImage: "arrow.down.doc") }
                }
            }
            Button { renameText = entry.name; renaming = entry } label: { Label("Đổi tên", systemImage: "pencil") }
            Button { pane.cut(entry) } label: { Label("Di chuyển (cắt)", systemImage: "scissors") }
            Button(role: .destructive) { deleting = entry } label: { Label("Xóa", systemImage: "trash") }
        }

        #if os(macOS)
        Group {
            if entry.isDir {
                content
                    .onDrop(of: [UTType.sftpRef, UTType.fileURL], isTargeted: nil) { providers in
                        handleDrop(providers, intoFolder: full)
                    }
            } else {
                content
            }
        }
        .onDrag { pane.isReady ? ref.itemProvider() : NSItemProvider() }
        #else
        content
            .draggable(ref)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { deleting = entry } label: { Label("Xóa", systemImage: "trash") }
                Button { renameText = entry.name; renaming = entry } label: { Label("Đổi tên", systemImage: "pencil") }
                    .tint(.blue)
            }
            .swipeActions(edge: .leading) {
                Button { pane.cut(entry) } label: { Label("Cắt", systemImage: "scissors") }.tint(.orange)
                if !entry.isDir && !pane.isLocal {
                    Button { startDownload(entry) } label: { Label("Tải về", systemImage: "arrow.down.doc") }.tint(.green)
                }
            }
        if entry.isDir {
            content.dropDestination(for: SFTPRef.self) { items, _ in
                for it in items { pane.receive(it, intoFolder: full) }
                return !items.isEmpty
            }
        } else {
            content
        }
        #endif
    }
}

// Tài liệu tạm để xuất tệp tải về ra Files (fileExporter chọn nơi lưu).
struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.data] }
    var data: Data
    var name: String
    var contentType: UTType {
        UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }
    init(data: Data, name: String) { self.data = data; self.name = name }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        name = configuration.file.filename ?? "file"
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// Màn 2 Server: hai khung kéo–thả copy giữa hai server, hoặc giữa máy này và server.
// Màn rộng (iPad/Mac) xếp cạnh nhau; iPhone hẹp xếp trên–dưới cho đỡ chật.
struct DualPaneView: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var left = PaneModel()
    @State private var right = PaneModel()

    private var stackVertically: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        Group {
            if stackVertically {
                // iPhone: 2 picker chọn nguồn xếp trên–dưới, 2 danh sách file chia đôi trái–phải.
                VStack(spacing: 0) {
                    PaneView(pane: left, tag: "Trái", showBody: false)
                    Divider()
                    PaneView(pane: right, tag: "Phải", showBody: false)
                    Divider().background(Color.accentColor.opacity(0.4))
                    HStack(spacing: 0) {
                        PaneView(pane: left, showToolbar: false)
                        Divider()
                        PaneView(pane: right, showToolbar: false)
                    }
                }
            } else {
                // iPad/Mac: 2 khung đầy đủ cạnh nhau.
                HStack(spacing: 0) {
                    PaneView(pane: left)
                    Divider()
                    PaneView(pane: right)
                }
            }
        }
        .navigationTitle("2 Server — kéo–thả copy (máy này ⟷ server)")
        .onAppear { left.attach(model); right.attach(model) }
    }
}

// Sửa nội dung tệp text: trên server qua SFTP, hoặc tệp trên máy.
struct FileEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: PaneSource
    let path: String
    let name: String
    var onSaved: () -> Void = {}

    @State private var text = ""
    @State private var loading = true
    @State private var binary = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Đang tải…")
                } else if let error {
                    ContentUnavailableView("Không mở được", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if binary {
                    ContentUnavailableView("Tệp nhị phân", systemImage: "doc.questionmark",
                                           description: Text("Không phải tệp văn bản nên không sửa được."))
                } else {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
            }
            .navigationTitle(name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Đang lưu…" : "Lưu") { save() }
                        .disabled(loading || binary || saving || error != nil)
                }
            }
        }
        .task { await load() }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 460)
        #endif
    }

    private func load() async {
        do {
            let data: Data
            switch source {
            case .local:
                data = try LocalFS.read(path)
            case .host(let id):
                guard let cfg = model.config(forHostId: id) else {
                    error = "Không tìm thấy server."; loading = false; return
                }
                data = try await model.ssh.readFile(cfg, path: path)
            case .unset:
                error = "Chưa chọn nguồn."; loading = false; return
            }
            if let s = String(data: data, encoding: .utf8) { text = s } else { binary = true }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func save() {
        saving = true
        Task {
            do {
                switch source {
                case .local:
                    try LocalFS.write(Data(text.utf8), to: path)
                case .host(let id):
                    guard let cfg = model.config(forHostId: id) else { saving = false; return }
                    try await model.ssh.writeFile(cfg, path: path, data: Data(text.utf8))
                case .unset:
                    saving = false; return
                }
                onSaved()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}
