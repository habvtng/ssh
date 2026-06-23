// Terminal SSH: SwiftTerm hiển thị, Citadel mở PTY shell và stream 2 chiều.
// TerminalView cùng tên class trên macOS (NSView) lẫn iOS (UIView) nên dùng chung được.
import SwiftUI
import SwiftTerm
import Citadel
import NIOCore
import NIOSSH

#if os(macOS)
import AppKit
typealias PlatformTermFont = NSFont
#else
import UIKit
typealias PlatformTermFont = UIFont
#endif

// Bộ điều khiển: nối phím gõ của TerminalView → PTY stdin, và PTY stdout → màn hình.
final class SSHTerminalController: NSObject, TerminalViewDelegate {
    let terminalView: TerminalView
    private let config: ConnectionConfig
    private let manager: SSHManager
    private let initialCommand: String?
    private var task: Task<Void, Never>?
    private var writer: TTYStdinWriter?

    init(config: ConnectionConfig, manager: SSHManager, initialCommand: String? = nil) {
        self.config = config
        self.manager = manager
        self.initialCommand = initialCommand
        let font = PlatformTermFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        self.terminalView = TerminalView(frame: .init(x: 0, y: 0, width: 600, height: 400), font: font)
        super.init()
        terminalView.terminalDelegate = self
        start()
    }

    private func start() {
        let term = terminalView.getTerminal()
        let cols = term.cols, rows = term.rows
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await self.manager.connect(self.config)
                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: cols,
                    terminalRowHeight: rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([.ECHO: 1, .ICANON: 1])
                )
                try await client.withPTY(request) { inbound, outbound in
                    self.writer = outbound
                    if let cmd = self.initialCommand, !cmd.isEmpty {
                        try? await outbound.write(ByteBuffer(string: cmd + "\n"))
                    }
                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buf), .stderr(let buf):
                            let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes) ?? []
                            await MainActor.run { self.terminalView.feed(byteArray: bytes[...]) }
                        }
                    }
                }
            } catch {
                let msg = "\r\n\u{1b}[31m[lỗi: \(error.localizedDescription)]\u{1b}[0m\r\n"
                await MainActor.run { self.terminalView.feed(text: msg) }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        writer = nil
    }

    // --- TerminalViewDelegate ---
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        Task { [weak self] in
            try? await self?.writer?.write(ByteBuffer(bytes: bytes))
        }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { [weak self] in
            try? await self?.writer?.changeSize(cols: newCols, rows: newRows, pixelWidth: 0, pixelHeight: 0)
        }
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

// Cầu nối SwiftUI ↔ TerminalView (NSView/UIView).
struct SSHTerminalRepresentable {
    let config: ConnectionConfig
    let manager: SSHManager

    func makeController() -> SSHTerminalController {
        SSHTerminalController(config: config, manager: manager)
    }
}

#if os(macOS)
struct TerminalScreenView: NSViewRepresentable {
    let config: ConnectionConfig
    let manager: SSHManager
    var initialCommand: String? = nil

    func makeCoordinator() -> SSHTerminalController { SSHTerminalController(config: config, manager: manager, initialCommand: initialCommand) }
    func makeNSView(context: Context) -> TerminalView { context.coordinator.terminalView }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
    static func dismantleNSView(_ nsView: TerminalView, coordinator: SSHTerminalController) { coordinator.stop() }
}
#else
struct TerminalScreenView: UIViewRepresentable {
    let config: ConnectionConfig
    let manager: SSHManager
    var initialCommand: String? = nil

    func makeCoordinator() -> SSHTerminalController { SSHTerminalController(config: config, manager: manager, initialCommand: initialCommand) }
    func makeUIView(context: Context) -> TerminalView { context.coordinator.terminalView }
    func updateUIView(_ uiView: TerminalView, context: Context) {}
    static func dismantleUIView(_ uiView: TerminalView, coordinator: SSHTerminalController) { coordinator.stop() }
}
#endif
