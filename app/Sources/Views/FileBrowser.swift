// Khung duyệt file SFTP tái dùng + kiểu kéo–thả. Dùng cho cả màn 2 Server lẫn tab SFTP của host.
import SwiftUI
import UniformTypeIdentifiers

// Dữ liệu kéo–thả: nguồn (host + đường dẫn tuyệt đối).
struct SFTPRef: Codable, Transferable {
    var hostId: UUID
    var path: String
    var name: String
    var isDir: Bool
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

@MainActor
@Observable
final class PaneModel {
    private var app: AppModel?
    var hostId: UUID?
    var path: String = ""
    var entries: [FileEntry] = []
    var status: String = ""
    var busy = false

    func attach(_ model: AppModel) { if app == nil { app = model } }

    func selectHost(_ id: UUID?) {
        hostId = id; entries = []; path = ""; status = ""
        if id != nil { Task { await load(".") } }
    }
    func reload() { Task { await load(path.isEmpty ? "." : path) } }
    func up() { Task { await load(PathUtil.parent(path)) } }
    func open(_ entry: FileEntry) {
        guard entry.isDir else { return }
        Task { await load(PathUtil.join(path, entry.name)) }
    }

    func load(_ p: String) async {
        guard let app, let id = hostId, let cfg = app.config(forHostId: id) else { return }
        busy = true; status = "đang tải…"
        do {
            let real = try await app.ssh.realPath(cfg, p)
            let items = try await app.ssh.list(cfg, path: real)
            path = real; entries = items; status = ""
        } catch {
            status = "Lỗi: \(error.localizedDescription)"
        }
        busy = false
    }

    // --- Tạo / sửa / xóa ---
    func makeDir(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
        perform("✓ Đã tạo thư mục \"\(n)\"") { app, cfg in
            try await app.ssh.makeDir(cfg, path: PathUtil.join(self.path, n))
        }
    }
    func makeFile(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
        perform("✓ Đã tạo tệp \"\(n)\"") { app, cfg in
            try await app.ssh.makeFile(cfg, path: PathUtil.join(self.path, n))
        }
    }
    func rename(_ entry: FileEntry, to newName: String) {
        let n = newName.trimmingCharacters(in: .whitespaces); guard !n.isEmpty, n != entry.name else { return }
        perform("✓ Đã đổi tên thành \"\(n)\"") { app, cfg in
            try await app.ssh.rename(cfg, from: PathUtil.join(self.path, entry.name),
                                     to: PathUtil.join(self.path, n))
        }
    }
    func remove(_ entry: FileEntry) {
        perform("✓ Đã xóa \"\(entry.name)\"") { app, cfg in
            try await app.ssh.delete(cfg, path: PathUtil.join(self.path, entry.name))
        }
    }

    // Di chuyển trong cùng server: cắt một mục rồi dán vào thư mục đang mở (dùng rename).
    var moveSource: (path: String, name: String)?
    func cut(_ entry: FileEntry) {
        moveSource = (PathUtil.join(path, entry.name), entry.name)
        status = "✂️ Đã cắt \"\(entry.name)\" — mở thư mục đích rồi bấm Dán."
    }
    func paste() {
        guard let src = moveSource else { return }
        let dest = PathUtil.join(path, src.name)
        if dest == src.path { status = "Đã ở đúng thư mục này."; return }
        perform("✓ Đã di chuyển \"\(src.name)\"") { app, cfg in
            try await app.ssh.rename(cfg, from: src.path, to: dest)
        }
        moveSource = nil
    }

    // --- Tải lên / tải về ---
    // Upload: ghi dữ liệu từ máy lên thư mục đang mở của server.
    func upload(name: String, data: Data) {
        let n = name.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
        perform("✓ Đã tải lên \"\(n)\" (\(formatSize(UInt64(data.count))))") { app, cfg in
            try await app.ssh.writeFile(cfg, path: PathUtil.join(self.path, n), data: data)
        }
    }

    // Download: lấy toàn bộ nội dung tệp về để người dùng chọn nơi lưu.
    func download(_ entry: FileEntry) async -> Data? {
        guard let app, let id = hostId, let cfg = app.config(forHostId: id) else {
            status = "Chọn server trước."; return nil
        }
        busy = true; status = "⏳ Đang tải \"\(entry.name)\"…"
        defer { busy = false }
        do {
            let data = try await app.ssh.downloadAll(cfg, path: PathUtil.join(path, entry.name))
            status = "✓ Đã tải \"\(entry.name)\" (\(formatSize(UInt64(data.count)))) — chọn nơi lưu."
            return data
        } catch {
            status = "Lỗi tải: \(error.localizedDescription)"; return nil
        }
    }

    private func perform(_ okMsg: String, _ work: @escaping (AppModel, ConnectionConfig) async throws -> Void) {
        guard let app, let id = hostId, let cfg = app.config(forHostId: id) else {
            status = "Chọn server trước."; return
        }
        Task {
            busy = true; status = "đang xử lý…"
            do {
                try await work(app, cfg)
                status = okMsg
                await load(path.isEmpty ? "." : path)
            } catch {
                status = "Lỗi: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    // Nhận một mục được thả vào: copy từ nguồn sang host của khung này.
    func receive(_ ref: SFTPRef, intoFolder folder: String?) {
        guard let app, let id = hostId, let dstCfg = app.config(forHostId: id) else {
            status = "Chọn server cho khung đích trước."; return
        }
        guard let srcCfg = app.config(forHostId: ref.hostId) else { return }
        let dstDir = folder ?? path
        Task {
            busy = true; status = "⏳ Đang copy \"\(ref.name)\"…"
            do {
                let r = try await app.ssh.transfer(from: srcCfg, srcPath: ref.path,
                                                   to: dstCfg, dstDir: dstDir, name: ref.name)
                status = "✓ Đã copy \"\(ref.name)\" — \(r.files) file, \(formatSize(UInt64(r.bytes)))"
                await load(path.isEmpty ? "." : path)
            } catch {
                status = "Lỗi copy: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

struct PaneView: View {
    @Environment(AppModel.self) private var model
    var pane: PaneModel
    var tag: String? = nil          // nhãn "Trái"/"Phải" cho layout iPhone
    var showToolbar = true          // hàng chọn server + nút
    var showBody = true             // breadcrumb + danh sách + trạng thái

    @State private var showNewFolder = false
    @State private var showNewFile = false
    @State private var newName = ""
    @State private var renaming: FileEntry?
    @State private var renameText = ""
    @State private var deleting: FileEntry?
    @State private var editing: FileEntry?
    @State private var showImporter = false
    @State private var exportFile: ExportFile?

    var body: some View {
        VStack(spacing: 0) {
            if showToolbar {
                toolbar
                if showBody { Divider() }
            }
            if showBody { bodyView }
        }
    }

    // Hàng chọn server + lên thư mục cha + tải lại.
    @ViewBuilder private var toolbar: some View {
        HStack(spacing: 8) {
            if let tag {
                Text(tag).font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
            }
            Picker("Server", selection: Binding(get: { pane.hostId }, set: { pane.selectHost($0) })) {
                Text("— chọn server —").tag(UUID?.none)
                ForEach(model.hosts) { h in
                    Text(h.label.isEmpty ? h.host : h.label).tag(UUID?.some(h.id))
                }
            }
            .labelsHidden()
            Button { pane.up() } label: { Image(systemName: "arrow.up") }
                .disabled(pane.hostId == nil)
            Button { pane.reload() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(pane.hostId == nil)
            if pane.moveSource != nil {
                Button { pane.paste() } label: { Image(systemName: "doc.on.clipboard") }
            }
            Button { showImporter = true } label: { Image(systemName: "arrow.up.doc") }
                .disabled(pane.hostId == nil)
            Menu {
                Button { newName = ""; showNewFolder = true } label: { Label("Thư mục mới", systemImage: "folder.badge.plus") }
                Button { newName = ""; showNewFile = true } label: { Label("Tệp mới", systemImage: "doc.badge.plus") }
                Button { showImporter = true } label: { Label("Tải tệp từ máy lên", systemImage: "arrow.up.doc") }
            } label: { Image(systemName: "plus") }
                .disabled(pane.hostId == nil)
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

    // Breadcrumb + danh sách file (vùng kéo–thả) + thanh trạng thái.
    @ViewBuilder private var bodyView: some View {
        VStack(spacing: 0) {
            Text(pane.path.isEmpty ? " " : pane.path)
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
            Divider()

            List {
                ForEach(pane.entries) { entry in
                    row(entry)
                }
            }
            .listStyle(.plain)
            .frame(maxHeight: .infinity)
            .overlay {
                if pane.entries.isEmpty && pane.hostId != nil && !pane.busy {
                    Text("(thư mục trống)").font(.caption).foregroundStyle(.secondary)
                } else if pane.hostId == nil {
                    Text("Chọn server").font(.caption).foregroundStyle(.secondary)
                }
            }
            .dropDestination(for: SFTPRef.self) { items, _ in
                for it in items { pane.receive(it, intoFolder: nil) }
                return !items.isEmpty
            }

            Divider()
            HStack(spacing: 8) {
                if pane.busy { ProgressView().controlSize(.small) }
                Text(pane.status.isEmpty ? "Sẵn sàng" : pane.status)
                    .font(.caption2).lineLimit(2)
                Spacer()
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
            if let id = pane.hostId {
                FileEditorView(hostId: id, path: PathUtil.join(pane.path, entry.name), name: entry.name) {
                    pane.status = "✓ Đã lưu \"\(entry.name)\""
                }
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

    @ViewBuilder
    private func row(_ entry: FileEntry) -> some View {
        let full = PathUtil.join(pane.path, entry.name)
        let ref = SFTPRef(hostId: pane.hostId ?? UUID(), path: full, name: entry.name, isDir: entry.isDir)
        let content = HStack(spacing: 8) {
            Image(systemName: entry.icon)
                .foregroundStyle(entry.isDir ? Color.accentColor : .secondary)
            Text(entry.name).lineLimit(1)
            Spacer()
            Text(entry.isDir ? "" : formatSize(entry.size))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { if entry.isDir { pane.open(entry) } else { editing = entry } }
        .draggable(ref)
        .contextMenu {
            if !entry.isDir {
                Button { editing = entry } label: { Label("Sửa nội dung", systemImage: "square.and.pencil") }
                Button { startDownload(entry) } label: { Label("Tải về máy", systemImage: "arrow.down.doc") }
            }
            Button { renameText = entry.name; renaming = entry } label: { Label("Đổi tên", systemImage: "pencil") }
            Button { pane.cut(entry) } label: { Label("Di chuyển (cắt)", systemImage: "scissors") }
            Button(role: .destructive) { deleting = entry } label: { Label("Xóa", systemImage: "trash") }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleting = entry } label: { Label("Xóa", systemImage: "trash") }
            Button { renameText = entry.name; renaming = entry } label: { Label("Đổi tên", systemImage: "pencil") }
                .tint(.blue)
        }
        .swipeActions(edge: .leading) {
            Button { pane.cut(entry) } label: { Label("Cắt", systemImage: "scissors") }.tint(.orange)
            if !entry.isDir {
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

// Màn 2 Server: hai khung kéo–thả copy giữa hai server.
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
                // iPhone: 2 picker chọn server xếp trên–dưới, 2 danh sách file chia đôi trái–phải.
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
        .navigationTitle("2 Server — kéo–thả copy")
        .onAppear { left.attach(model); right.attach(model) }
    }
}

// Sửa nội dung tệp text trên server qua SFTP.
struct FileEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let hostId: UUID
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
        guard let cfg = model.config(forHostId: hostId) else { error = "Không tìm thấy server."; loading = false; return }
        do {
            let data = try await model.ssh.readFile(cfg, path: path)
            if let s = String(data: data, encoding: .utf8) { text = s } else { binary = true }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func save() {
        guard let cfg = model.config(forHostId: hostId) else { return }
        saving = true
        Task {
            do {
                try await model.ssh.writeFile(cfg, path: path, data: Data(text.utf8))
                onSaved()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}
