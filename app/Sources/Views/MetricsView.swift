// Metrics: hiển thị TẤT CẢ server cùng lúc, mỗi server một card với vòng tròn CPU/Mem/Disk,
// cột Net + I/O, header có ping/nhiệt độ/uptime/load. Tự làm mới định kỳ. Tối ưu cho Linux.
import SwiftUI

struct HostMetric {
    var cpu = 0.0          // %
    var cores = ""
    var load = ""
    var uptimeSec = 0.0
    var tempC: Double? = nil
    var memTotal = 0.0     // bytes
    var memUsed = 0.0
    var diskSize = 0.0
    var diskUsed = 0.0
    var netUp = 0.0        // bytes/s
    var netDown = 0.0
    var netUpTot = 0.0
    var netDownTot = 0.0
    var ioWrite = 0.0
    var ioRead = 0.0
    var ioWriteTot = 0.0
    var ioReadTot = 0.0
    var pingMs: Double? = nil
    var error: String? = nil
    var hasData = false
}

struct MetricsListView: View {
    @Environment(AppModel.self) private var model
    @State private var data: [UUID: HostMetric] = [:]
    @State private var editingHost: Host?
    @State private var showHostSheet = false

    var body: some View {
        NavigationStack {
            Group {
                if model.hosts.isEmpty {
                    ContentUnavailableView("Chưa có host", systemImage: "server.rack",
                                           description: Text("Bấm icon server ở góc trên để thêm server."))
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(model.hosts) { host in
                                MetricCardView(host: host, m: data[host.id] ?? HostMetric())
                                    .contextMenu {
                                        Button { editingHost = host; showHostSheet = true } label: {
                                            Label("Sửa thông tin", systemImage: "pencil")
                                        }
                                        Button(role: .destructive) { model.delete(host: host) } label: {
                                            Label("Xóa server", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Metrics")
            .toolbar {
                ToolbarItem { NavigationLink { KeysView() } label: { Image(systemName: "key") } }
                ToolbarItem { NavigationLink { ServerListView() } label: { Image(systemName: "server.rack") } }
            }
            .sheet(isPresented: $showHostSheet) { HostEditView(host: editingHost) }
            .task { await autoRefresh() }
        }
    }

    private func autoRefresh() async {
        while !Task.isCancelled {
            await refreshAll()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func refreshAll() async {
        // Gom config trên MainActor trước, rồi fetch song song (chỉ chạm actor SSHManager).
        let jobs: [(UUID, ConnectionConfig)] = model.hosts.map { ($0.id, model.config(for: $0)) }
        let ssh = model.ssh
        await withTaskGroup(of: (UUID, HostMetric).self) { group in
            for (id, cfg) in jobs {
                group.addTask { (id, await Self.fetch(ssh, cfg)) }
            }
            for await (id, m) in group { data[id] = m }
        }
    }

    private static func fetch(_ ssh: SSHManager, _ cfg: ConnectionConfig) async -> HostMetric {
        var m = HostMetric()
        do {
            let t0 = Date()
            _ = try await ssh.run(cfg, command: "echo")
            m.pingMs = Date().timeIntervalSince(t0) * 1000
            let out = try await ssh.run(cfg, command: script)
            parse(out, into: &m)
            m.hasData = true
        } catch {
            m.error = error.localizedDescription
        }
        return m
    }

    // Script gộp: lấy 2 mẫu cách nhau 0.5s để tính %CPU và tốc độ net/io.
    private static let script = """
    S=0.5
    c1=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' /proc/stat)
    n1=$(awk 'NR>2 && $1!="lo:"{rx+=$2; tx+=$10} END{print rx+0, tx+0}' /proc/net/dev)
    k1=$(awk '$3 ~ /^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$/{rd+=$6; wr+=$10} END{print (rd+0)*512, (wr+0)*512}' /proc/diskstats)
    sleep $S
    c2=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' /proc/stat)
    n2=$(awk 'NR>2 && $1!="lo:"{rx+=$2; tx+=$10} END{print rx+0, tx+0}' /proc/net/dev)
    k2=$(awk '$3 ~ /^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$/{rd+=$6; wr+=$10} END{print (rd+0)*512, (wr+0)*512}' /proc/diskstats)
    set -- $c1; ct1=$1; ci1=$2; set -- $c2; ct2=$1; ci2=$2
    set -- $n1; nrx1=$1; ntx1=$2; set -- $n2; nrx2=$1; ntx2=$2
    set -- $k1; krd1=$1; kwr1=$2; set -- $k2; krd2=$1; kwr2=$2
    echo "CPU:$(awk -v a=$ct1 -v b=$ci1 -v c=$ct2 -v d=$ci2 'BEGIN{dt=c-a;di=d-b; if(dt<=0)print 0; else printf "%d",(1-di/dt)*100}')"
    echo "CORES:$(nproc 2>/dev/null)"
    echo "LOAD:$(cut -d' ' -f1 /proc/loadavg)"
    echo "UP:$(cut -d' ' -f1 /proc/uptime)"
    echo "TEMP:$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -rn | head -1)"
    awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{print "MEMTOTAL:"t*1024; print "MEMUSED:"(t-a)*1024}' /proc/meminfo
    df -B1 / 2>/dev/null | awk 'NR==2{print "DISKSIZE:"$2; print "DISKUSED:"$3}'
    awk -v a=$nrx1 -v b=$nrx2 -v s=$S 'BEGIN{print "NETDOWN:" int((b-a)/s)}'
    awk -v a=$ntx1 -v b=$ntx2 -v s=$S 'BEGIN{print "NETUP:" int((b-a)/s)}'
    echo "NETDOWNTOT:$nrx2"; echo "NETUPTOT:$ntx2"
    awk -v a=$krd1 -v b=$krd2 -v s=$S 'BEGIN{print "IOREAD:" int((b-a)/s)}'
    awk -v a=$kwr1 -v b=$kwr2 -v s=$S 'BEGIN{print "IOWRITE:" int((b-a)/s)}'
    echo "IOREADTOT:$krd2"; echo "IOWRITETOT:$kwr2"
    """

    private static func parse(_ out: String, into m: inout HostMetric) {
        var d: [String: String] = [:]
        for line in out.split(separator: "\n") {
            guard let i = line.firstIndex(of: ":") else { continue }
            d[String(line[..<i])] = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        }
        func num(_ k: String) -> Double { Double(d[k] ?? "") ?? 0 }
        m.cpu = num("CPU")
        m.cores = d["CORES"] ?? ""
        m.load = d["LOAD"] ?? ""
        m.uptimeSec = num("UP")
        if let t = d["TEMP"], let v = Double(t), v > 0, v < 200000 { m.tempC = v / 1000 }
        m.memTotal = num("MEMTOTAL"); m.memUsed = num("MEMUSED")
        m.diskSize = num("DISKSIZE"); m.diskUsed = num("DISKUSED")
        m.netDown = num("NETDOWN"); m.netUp = num("NETUP")
        m.netDownTot = num("NETDOWNTOT"); m.netUpTot = num("NETUPTOT")
        m.ioRead = num("IOREAD"); m.ioWrite = num("IOWRITE")
        m.ioReadTot = num("IOREADTOT"); m.ioWriteTot = num("IOWRITETOT")
    }
}

// MARK: - Card

struct MetricCardView: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let host: Host
    let m: HostMetric

    private var compact: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            Divider()
            if m.error != nil && !m.hasData {
                Text(m.error!).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if compact {
                HStack(alignment: .top, spacing: 8) {
                    gauge("CPU", m.cpu / 100, "\(m.cores) C")
                    gauge("Mem", frac(m.memUsed, m.memTotal), human(m.memTotal))
                    gauge("Disk", frac(m.diskUsed, m.diskSize), human(m.diskSize))
                }
                HStack(alignment: .top, spacing: 16) {
                    netColumn; ioColumn
                }
            } else {
                HStack(alignment: .top, spacing: 18) {
                    gauge("CPU", m.cpu / 100, "\(m.cores) C")
                    gauge("Mem", frac(m.memUsed, m.memTotal), human(m.memTotal))
                    gauge("Disk", frac(m.diskUsed, m.diskSize), human(m.diskSize))
                    Spacer(minLength: 0)
                    netColumn
                    ioColumn
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var header: some View {
        HStack {
            Image(systemName: "circle.hexagongrid.fill").foregroundStyle(.orange)
            Text(host.label.isEmpty ? host.host : host.label).font(.headline)
            Spacer()
            HStack(spacing: 12) {
                if let p = m.pingMs {
                    stat("dot.radiowaves.left.and.right", String(format: "%.0fms", p),
                         p < 100 ? .green : (p < 300 ? .yellow : .red))
                }
                if let t = m.tempC {
                    stat("thermometer.medium", String(format: "%.0f°C", t),
                         t < 70 ? .green : (t < 85 ? .orange : .red))
                }
                if m.uptimeSec > 0 { stat("power", uptime(m.uptimeSec), .secondary) }
                if !m.load.isEmpty { stat("waveform.path.ecg", m.load, .secondary) }
            }
            .font(.caption.weight(.medium))
        }
    }

    private func stat(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 3) { Image(systemName: icon); Text(text) }.foregroundStyle(color)
    }

    private func gauge(_ title: String, _ fraction: Double, _ caption: String) -> some View {
        let f = min(max(fraction, 0), 1)
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
            .frame(width: compact ? 60 : 72, height: compact ? 60 : 72)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var netColumn: some View {
        VStack(spacing: 4) {
            Text("Net").font(.subheadline).foregroundStyle(.secondary)
            arrowLine(up: true, rate: m.netUp, total: m.netUpTot)
            arrowLine(up: false, rate: m.netDown, total: m.netDownTot)
        }
        .frame(maxWidth: .infinity)
    }

    private var ioColumn: some View {
        VStack(spacing: 4) {
            Text("I/O").font(.subheadline).foregroundStyle(.secondary)
            arrowLine(up: true, rate: m.ioWrite, total: m.ioWriteTot)
            arrowLine(up: false, rate: m.ioRead, total: m.ioReadTot)
        }
        .frame(maxWidth: .infinity)
    }

    private func arrowLine(up: Bool, rate: Double, total: Double) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 2) {
                Image(systemName: up ? "arrow.up" : "arrow.down")
                Text(human(rate)).monospacedDigit()
            }.font(.caption.weight(.medium))
            Text(human(total)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    // helpers
    private func frac(_ used: Double, _ total: Double) -> Double { total > 0 ? used / total : 0 }
    private func human(_ bytes: Double) -> String {
        let u = ["B", "K", "M", "G", "T", "P"]; var x = bytes; var i = 0
        while x >= 1024 && i < u.count - 1 { x /= 1024; i += 1 }
        return i == 0 ? "\(Int(x)) \(u[i])" : String(format: "%.1f %@", x, u[i])
    }
    private func uptime(_ s: Double) -> String {
        let d = Int(s) / 86400, h = (Int(s) % 86400) / 3600, mn = (Int(s) % 3600) / 60
        if d > 0 { return "\(d)d" }
        if h > 0 { return "\(h)h" }
        return "\(mn)m"
    }
}
