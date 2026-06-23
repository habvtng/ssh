// Chi tiết một host: chuyển giữa Terminal và trình duyệt file (SFTP).
import SwiftUI

struct HostDetailView: View {
    @Environment(AppModel.self) private var model
    let host: Host
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Terminal").tag(0)
                Text("Tệp (SFTP)").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()

            if tab == 0 {
                TerminalScreenView(config: model.config(for: host), manager: model.ssh)
                    .id(host.id)
            } else {
                SingleBrowser(host: host).id(host.id)
            }
        }
        .navigationTitle(host.label.isEmpty ? host.host : host.label)
    }
}

// Trình duyệt SFTP cho một host đã chọn sẵn.
struct SingleBrowser: View {
    @Environment(AppModel.self) private var model
    let host: Host
    @State private var pane = PaneModel()

    var body: some View {
        PaneView(pane: pane)
            .onAppear {
                pane.attach(model)
                if pane.hostId == nil { pane.selectHost(host.id) }
            }
    }
}
