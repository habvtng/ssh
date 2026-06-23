// tre360 SSH — app native macOS + iOS. SSH/SFTP chạy thẳng trên thiết bị (Citadel).
import SwiftUI

@main
struct Tre360SSHApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView().environment(model)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        #endif
    }
}
