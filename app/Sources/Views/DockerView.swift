// Quản lý Docker qua SSH: liệt kê + start/stop/restart/xóa container, xem log, liệt kê/xóa image.
// Chạy lệnh `docker ...` trên host. Tối ưu cho host đăng nhập quyền root (hoặc user trong nhóm docker).
import SwiftUI

struct DockerContainer: Identifiable, Hashable {
    var id: String
    var name: String
    var image: String
    var state: String
    var status: String
    // Thống kê realtime (chỉ có với container đang chạy, lấy từ `docker stats`).
    var cpuPerc: String = ""
    var memUsage: String = ""
    var memPerc: String = ""
    var netIO: String = ""
    var blockIO: String = ""
    var isRunning: Bool { state.lowercased() == "running" }
    var hasStats: Bool { !cpuPerc.isEmpty }
}

// Tổng quan Docker của một host (lấy từ `docker info`).
struct DockerInfo {
    var version = ""
    var running = 0
    var stopped = 0
    var total = 0
    var images = 0
    var ncpu = 0
    var memTotal = 0.0   // bytes
    var os = ""
    var error: String? = nil
    var hasData = false
}

struct DockerImage: Identifiable {
    var id: String
    var repoTag: String
    var size: String
}

private struct LogsItem: Identifiable { let id = UUID(); let container: DockerContainer }

// MARK: - Danh sách host Docker (card tổng quan), chọn host để xem container.

struct DockerHostsView: View {
    @Environment(AppModel.self) private var model
    @State private var data: [UUID: DockerInfo] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if model.hosts.isEmpty {
                    ContentUnavailableView("Chưa có host", systemImage: "shippingbox",
                                           description: Text("Bấm icon server ở góc trên để thêm server."))
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(model.hosts) { host in
                                NavigationLink(value: host) {
                                    DockerHostCard(host: host, info: data[host.id] ?? DockerInfo())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Docker")
            .navigationDestination(for: Host.self) { DockerView(host: $0) }
            .toolbar {
                ToolbarItem { NavigationLink { KeysView() } label: { Image(systemName: "key") } }
                ToolbarItem { NavigationLink { ServerListView() } label: { Image(systemName: "server.rack") } }
            }
            .task { await autoRefresh() }
        }
    }

    private func autoRefresh() async {
        while !Task.isCancelled {
            await refreshAll()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func refreshAll() async {
        let jobs: [(UUID, ConnectionConfig)] = model.hosts.map { ($0.id, model.config(for: $0)) }
        let ssh = model.ssh
        await withTaskGroup(of: (UUID, DockerInfo).self) { group in
            for (id, cfg) in jobs { group.addTask { (id, await Self.fetch(ssh, cfg)) } }
            for await (id, info) in group { data[id] = info }
        }
    }

    private static func fetch(_ ssh: SSHManager, _ cfg: ConnectionConfig) async -> DockerInfo {
        var info = DockerInfo()
        do {
            let fmt = "{{.ServerVersion}}|{{.ContainersRunning}}|{{.ContainersStopped}}|{{.Containers}}|{{.Images}}|{{.NCPU}}|{{.MemTotal}}|{{.OperatingSystem}}"
            let out = try await ssh.run(cfg, command: "(docker info --format '\(fmt)') 2>&1 || true")
            let line = out.trimmingCharacters(in: .whitespacesAndNewlines)
            let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if p.count >= 8, !p[0].isEmpty {
                info.version = p[0]
                info.running = Int(p[1]) ?? 0
                info.stopped = Int(p[2]) ?? 0
                info.total = Int(p[3]) ?? 0
                info.images = Int(p[4]) ?? 0
                info.ncpu = Int(p[5]) ?? 0
                info.memTotal = Double(p[6]) ?? 0
                info.os = p[7]
                info.hasData = true
            } else {
                info.error = line.isEmpty ? "Không đọc được Docker" : line
            }
        } catch {
            info.error = error.localizedDescription
        }
        return info
    }
}

struct DockerHostCard: View {
    let host: Host
    let info: DockerInfo

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "circle.hexagongrid.fill").foregroundStyle(.orange)
                Text(host.label.isEmpty ? host.host : host.label).font(.headline)
                Spacer()
                if info.hasData {
                    HStack(spacing: 4) {
                        Image(systemName: "shippingbox.fill").foregroundStyle(.blue)
                        Text(info.version).monospacedDigit()
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.gray.opacity(0.2))
                    .clipShape(Capsule())
                }
            }

            if !info.hasData && info.error == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Đang đọc Docker…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            } else if let e = info.error, !info.hasData {
                Text(e).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
            } else {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    stat("power", "Running", "\(info.running)", .green)
                    stat("power", "Stopped", "\(info.stopped)", info.stopped > 0 ? .red : .secondary)
                    stat("shippingbox", "Total", "\(info.total)", .primary)
                }
                HStack(alignment: .top, spacing: 8) {
                    stat("cpu", "CPU", "\(info.ncpu)C", .orange)
                    stat("memorychip", "Memory", human(info.memTotal), .purple)
                    stat("square.stack.3d.up", "Images", "\(info.images)", .blue)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func stat(_ icon: String, _ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }

    private func human(_ bytes: Double) -> String {
        let u = ["B", "K", "M", "G", "T", "P"]; var x = bytes; var i = 0
        while x >= 1024 && i < u.count - 1 { x /= 1024; i += 1 }
        return i == 0 ? "\(Int(x)) \(u[i])" : String(format: "%.1f %@", x, u[i])
    }
}

struct DockerView: View {
    @Environment(AppModel.self) private var model
    let host: Host

    enum Section: String, CaseIterable { case containers = "Containers", images = "Images" }
    @State private var section: Section = .containers
    @State private var containers: [DockerContainer] = []
    @State private var images: [DockerImage] = []
    @State private var loading = true
    @State private var working = false
    @State private var errMsg: String?
    @State private var notice = ""
    @State private var logs: LogsItem?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(8)
            Divider()

            Group {
                if loading && containers.isEmpty && images.isEmpty {
                    ProgressView("Đang đọc Docker…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errMsg, currentEmpty {
                    ContentUnavailableView("Không đọc được Docker", systemImage: "exclamationmark.triangle",
                                           description: Text(errMsg))
                } else {
                    list
                }
            }

            if working || !notice.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    if working { ProgressView().controlSize(.small) }
                    Text(notice.isEmpty ? "đang chạy…" : notice).font(.caption2).lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .navigationTitle("Docker")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem { Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") } }
        }
        .navigationDestination(for: DockerContainer.self) { c in
            ContainerDetailView(host: host, container: c)
        }
        .task(id: section) { await reload() }
        .sheet(item: $logs) { item in DockerLogsView(host: host, container: item.container) }
    }

    private var currentEmpty: Bool {
        section == .containers ? containers.isEmpty : images.isEmpty
    }

    @ViewBuilder private var list: some View {
        if section == .containers {
            ScrollView {
                if containers.isEmpty {
                    Text("Không có container.").foregroundStyle(.secondary).padding()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 12)], spacing: 12) {
                        ForEach(containers) { c in
                            NavigationLink(value: c) {
                                ContainerCardView(c: c)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: c) }
                        }
                    }
                    .padding()
                }
            }
            .refreshable { await reload() }
        } else {
            List {
                ForEach(images) { img in imageRow(img) }
                if images.isEmpty { Text("Không có image.").foregroundStyle(.secondary) }
            }
            #if os(iOS)
            .listStyle(.plain)
            #endif
            .refreshable { await reload() }
        }
    }

    @ViewBuilder private func menu(for c: DockerContainer) -> some View {
        if c.isRunning {
            Button { act("docker stop \(c.id)", "✓ Đã dừng \(c.name)") } label: { Label("Dừng", systemImage: "stop.circle") }
            Button { act("docker restart \(c.id)", "✓ Đã khởi động lại \(c.name)") } label: { Label("Khởi động lại", systemImage: "arrow.clockwise.circle") }
        } else {
            Button { act("docker start \(c.id)", "✓ Đã chạy \(c.name)") } label: { Label("Chạy", systemImage: "play.circle") }
        }
        Button { logs = LogsItem(container: c) } label: { Label("Xem log", systemImage: "doc.plaintext") }
        Button(role: .destructive) { act("docker rm -f \(c.id)", "✓ Đã xóa \(c.name)") } label: { Label("Xóa", systemImage: "trash") }
    }

    @ViewBuilder private func imageRow(_ img: DockerImage) -> some View {
        HStack {
            Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(img.repoTag).lineLimit(1)
                Text(img.size).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contextMenu {
            Button(role: .destructive) { act("docker rmi \(img.id)", "✓ Đã xóa image") } label: { Label("Xóa image", systemImage: "trash") }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { act("docker rmi \(img.id)", "✓ Đã xóa image") } label: { Label("Xóa", systemImage: "trash") }
        }
    }

    // MARK: lệnh
    private func dockerRun(_ cmd: String) async throws -> String {
        guard let cfg = model.config(forHostId: host.id) else { throw SSHFriendlyError(message: "Không tìm thấy server.") }
        // 2>&1 || true: gộp stderr, luôn exit 0 để lấy được nội dung lỗi (vd docker chưa cài / thiếu quyền).
        return try await model.ssh.run(cfg, command: "(\(cmd)) 2>&1 || true")
    }

    private func act(_ cmd: String, _ okMsg: String) {
        Task {
            working = true; notice = "đang chạy…"
            do {
                let out = try await dockerRun(cmd)
                notice = isDockerError(out) ? "Lỗi: \(out.trimmingCharacters(in: .whitespacesAndNewlines))" : okMsg
                await reload()
            } catch {
                notice = "Lỗi: \(error.localizedDescription)"
            }
            working = false
        }
    }

    private func reload() async {
        do {
            if section == .containers {
                let out = try await dockerRun("docker ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.State}}|{{.Status}}'")
                if isDockerError(out) { errMsg = out.trimmingCharacters(in: .whitespacesAndNewlines); containers = [] }
                else {
                    var list = parseContainers(out)
                    // Thống kê realtime cho container đang chạy.
                    let statsOut = try await dockerRun("docker stats --no-stream --format '{{.ID}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}'")
                    if !isDockerError(statsOut) {
                        let stats = parseStats(statsOut)
                        for i in list.indices {
                            if let s = stats.first(where: { list[i].id.hasPrefix($0.id) || $0.id.hasPrefix(list[i].id) }) {
                                list[i].cpuPerc = s.cpu; list[i].memUsage = s.mem; list[i].memPerc = s.memPct
                                list[i].netIO = s.net; list[i].blockIO = s.block
                            }
                        }
                    }
                    containers = list; errMsg = nil
                }
            } else {
                let out = try await dockerRun("docker images --format '{{.ID}}|{{.Repository}}:{{.Tag}}|{{.Size}}'")
                if isDockerError(out) { errMsg = out.trimmingCharacters(in: .whitespacesAndNewlines); images = [] }
                else { images = parseImages(out); errMsg = nil }
            }
        } catch {
            errMsg = error.localizedDescription
        }
        loading = false
    }

    private func isDockerError(_ out: String) -> Bool {
        let l = out.lowercased()
        return l.contains("command not found") || l.contains("not found")
            || l.contains("cannot connect to the docker daemon")
            || l.contains("permission denied") || l.contains("is not a docker command")
    }

    private func parseContainers(_ out: String) -> [DockerContainer] {
        out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 5, !p[0].isEmpty else { return nil }
            return DockerContainer(id: p[0], name: p[1], image: p[2], state: p[3], status: p[4])
        }
    }

    private func parseStats(_ out: String) -> [(id: String, cpu: String, mem: String, memPct: String, net: String, block: String)] {
        out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 6, !p[0].isEmpty else { return nil }
            return (p[0], p[1], p[2], p[3], p[4], p[5])
        }
    }

    private func parseImages(_ out: String) -> [DockerImage] {
        out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 3, !p[0].isEmpty else { return nil }
            return DockerImage(id: p[0], repoTag: p[1], size: p[2])
        }
    }
}

// MARK: - Card một container (vòng tròn CPU/Mem + Net ↑↓ + I/O R/W).

struct ContainerCardView: View {
    let c: DockerContainer

    var body: some View {
        VStack(spacing: 10) {
            header
            Divider()
            HStack(alignment: .top, spacing: 10) {
                gauge("CPU", percent: pct(c.cpuPerc), caption: c.hasStats ? c.cpuPerc : "—")
                gauge("Mem", percent: pct(c.memPerc), caption: c.hasStats ? firstPart(c.memUsage) : "—")
                pairColumn("Net", topVal: secondPart(c.netIO), bottomVal: firstPart(c.netIO),
                           topSym: "↑", bottomSym: "↓")
                pairColumn("I/O", topVal: firstPart(c.blockIO), bottomVal: secondPart(c.blockIO),
                           topSym: "R", bottomSym: "W")
            }
            Divider()
            footer
        }
        .padding()
        .background(Color.gray.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill").foregroundStyle(.blue)
            Text(c.name).font(.headline).lineLimit(1)
            Spacer(minLength: 8)
            Text("# \(c.id)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up").font(.caption).foregroundStyle(.secondary)
            Text(c.image).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Circle().fill(c.isRunning ? Color.green : Color.gray).frame(width: 7, height: 7)
            Text(c.status).font(.caption.weight(.medium))
                .foregroundStyle(c.isRunning ? .green : .secondary).lineLimit(1)
        }
    }

    private func gauge(_ title: String, percent: Double, caption: String) -> some View {
        let f = min(max(percent / 100, 0), 1)
        let color: Color = f < 0.7 ? .green : (f < 0.9 ? .orange : .red)
        return VStack(spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            ZStack {
                Circle().stroke(Color.gray.opacity(0.25), lineWidth: 6)
                Circle().trim(from: 0, to: f)
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(f * 100))%").font(.callout.bold().monospacedDigit()).foregroundStyle(color)
            }
            .frame(width: 60, height: 60)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private func pairColumn(_ title: String, topVal: String, bottomVal: String,
                            topSym: String, bottomSym: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                badge(topSym, .orange, topVal)
                badge(bottomSym, .blue, bottomVal)
            }
            .frame(height: 60)
            Text(" ").font(.caption)
        }
        .frame(maxWidth: .infinity)
    }

    private func badge(_ symbol: String, _ color: Color, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(symbol).font(.caption2.bold()).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(color).clipShape(Circle())
            Text(value.isEmpty ? "—" : value)
                .font(.caption.weight(.medium).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    // Parse "12.3%" -> 12.3
    private func pct(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
    }
    // "3.1GiB / 31GiB" -> "3.1GiB" / "31GiB"
    private func firstPart(_ s: String) -> String {
        s.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
    private func secondPart(_ s: String) -> String {
        let p = s.split(separator: "/")
        return p.count > 1 ? p[1].trimmingCharacters(in: .whitespaces) : ""
    }
}

// MARK: - Chi tiết container (docker inspect) + thao tác.

struct ContainerDetailInfo {
    var name = "", status = "", path = "", image = ""
    var ipv4 = "", ports = "", mounts = "", created = ""
}

struct ContainerDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: Host
    let container: DockerContainer

    @State private var d = ContainerDetailInfo()
    @State private var loading = true
    @State private var working = false
    @State private var notice = ""

    var body: some View {
        Form {
            Section("Basic Info") {
                row("Name", d.name.isEmpty ? container.name : d.name)
                row("Status", d.status.isEmpty ? container.state : d.status)
                row("ID", container.id)
                row("Path", d.path)
                row("Image", d.image.isEmpty ? container.image : d.image)
                row("IPv4", d.ipv4)
                row("Port Mapping", d.ports)
                row("Volume Binds", d.mounts)
                row("Created", d.created)
            }

            Section("Option") {
                actionRow("Start", "play.circle.fill", .green) {
                    act("docker start \(container.id)", "✓ Đã chạy")
                }
                actionRow("Stop", "stop.circle.fill", .gray) {
                    act("docker stop \(container.id)", "✓ Đã dừng")
                }
                actionRow("Restart", "arrow.triangle.2.circlepath.circle.fill", .red) {
                    act("docker restart \(container.id)", "✓ Đã khởi động lại")
                }
                Button {
                    Task {
                        working = true; notice = "đang xóa…"
                        _ = try? await dockerRun("docker rm -f \(container.id)")
                        working = false
                        dismiss()
                    }
                } label: {
                    Label {
                        Text("Remove").foregroundStyle(.red)
                    } icon: {
                        Image(systemName: "trash.circle.fill").foregroundStyle(.red)
                    }
                }

                NavigationLink {
                    TerminalScreenView(config: model.config(for: host), manager: model.ssh,
                                       initialCommand: "docker exec -it \(container.id) sh")
                        .navigationTitle(container.name)
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                } label: {
                    Label {
                        Text("Terminal")
                    } icon: {
                        Image(systemName: "terminal.fill").foregroundStyle(.blue)
                    }
                }
            }

            if working || !notice.isEmpty {
                Section {
                    HStack(spacing: 8) {
                        if working { ProgressView().controlSize(.small) }
                        Text(notice).font(.caption)
                        Spacer()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Container Detail")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay { if loading { ProgressView() } }
        .toolbar {
            ToolbarItem { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") } }
        }
        .task { await load() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value.isEmpty ? "—" : value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func actionRow(_ title: String, _ icon: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title).foregroundStyle(.primary)
            } icon: {
                Image(systemName: icon).foregroundStyle(color)
            }
        }
    }

    private func dockerRun(_ cmd: String) async throws -> String {
        guard let cfg = model.config(forHostId: host.id) else { throw SSHFriendlyError(message: "Không tìm thấy server.") }
        return try await model.ssh.run(cfg, command: "(\(cmd)) 2>&1 || true")
    }

    private func act(_ cmd: String, _ okMsg: String) {
        Task {
            working = true; notice = "đang chạy…"
            _ = try? await dockerRun(cmd)
            notice = okMsg
            await load()
            working = false
        }
    }

    private func load() async {
        loading = true
        let fmt = """
        NAME:{{.Name}}
        STATUS:{{.State.Status}}
        PATH:{{.Path}}
        IMAGE:{{.Config.Image}}
        IP:{{range $k,$v := .NetworkSettings.Networks}}{{$v.IPAddress}} {{end}}
        PORTS:{{range $p,$b := .NetworkSettings.Ports}}{{if $b}}{{range $b}}{{.HostIp}}:{{.HostPort}}->{{end}}{{end}}{{$p}} {{end}}
        MOUNTS:{{range .Mounts}}{{.Source}}:{{.Destination}}:{{if .RW}}rw{{else}}ro{{end}} {{end}}
        CREATED:{{.Created}}
        """
        do {
            let out = try await dockerRun("docker inspect \(container.id) --format '\(fmt)'")
            parse(out)
        } catch {
            notice = "Lỗi: \(error.localizedDescription)"
        }
        loading = false
    }

    private func parse(_ out: String) {
        var dict: [String: String] = [:]
        for line in out.split(separator: "\n") {
            guard let i = line.firstIndex(of: ":") else { continue }
            dict[String(line[..<i])] = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        }
        var info = ContainerDetailInfo()
        info.name = (dict["NAME"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        info.status = dict["STATUS"] ?? ""
        info.path = dict["PATH"] ?? ""
        info.image = dict["IMAGE"] ?? ""
        info.ipv4 = dict["IP"] ?? ""
        info.ports = dict["PORTS"] ?? ""
        info.mounts = dict["MOUNTS"] ?? ""
        if let c = dict["CREATED"], c.count >= 19 {
            info.created = String(c.prefix(19)).replacingOccurrences(of: "T", with: " ")
        }
        d = info
    }
}

// Xem log container.
struct DockerLogsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: Host
    let container: DockerContainer
    @State private var text = ""
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "(trống)" : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle(container.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
                ToolbarItem { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") } }
            }
        }
        .task { await load() }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 460)
        #endif
    }

    private func load() async {
        guard let cfg = model.config(forHostId: host.id) else { loading = false; return }
        loading = true
        do {
            text = try await model.ssh.run(cfg, command: "(docker logs --tail 400 \(container.id)) 2>&1 || true")
        } catch {
            text = "Lỗi: \(error.localizedDescription)"
        }
        loading = false
    }
}
