import SwiftUI
import AppKit

@main
struct UsageMenuBarApp: App {
    @StateObject private var store = QuotaStore()

    init() {
        // No Dock icon, no Cmd-Tab entry — pure menu bar utility.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            QuotaView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
