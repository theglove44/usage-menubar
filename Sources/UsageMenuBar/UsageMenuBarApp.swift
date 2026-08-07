import SwiftUI
import AppKit

@main
struct UsageMenuBarApp: App {
    @StateObject private var store = QuotaStore()
    @StateObject private var sessionStore = SessionActivityStore(
        provider: LocalSessionRunwayActivityProvider()
    )

    init() {
        // No Dock icon, no Cmd-Tab entry — pure menu bar utility.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            QuotaView(store: store, sessionStore: sessionStore)
        } label: {
            MenuBarLabel(store: store, sessionStore: sessionStore)
        }
        .menuBarExtraStyle(.window)
    }
}
