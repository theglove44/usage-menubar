import SwiftUI
import AppKit

@main
struct UsageMenuBarApp: App {
    @StateObject private var store: QuotaStore
    @StateObject private var sessionStore = SessionActivityStore(
        provider: LocalSessionRunwayActivityProvider()
    )
    @StateObject private var preferences: MenuBarPreferences

    init() {
        let preferences = MenuBarPreferences()
        _preferences = StateObject(wrappedValue: preferences)
        _store = StateObject(wrappedValue: QuotaStore(preferences: preferences))
        // No Dock icon, no Cmd-Tab entry — pure menu bar utility.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            QuotaView(store: store, sessionStore: sessionStore, preferences: preferences)
        } label: {
            MenuBarLabel(store: store, preferences: preferences)
        }
        .menuBarExtraStyle(.window)
    }
}
