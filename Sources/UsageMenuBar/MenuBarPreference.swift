import Foundation
import SwiftUI

// Which single provider the menu bar shows. The dropdown still lists every
// provider; this only controls the always-visible gauge in the menu bar.
enum MenuBarProvider: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }
}

@MainActor
final class MenuBarPreferences: ObservableObject {
    private static let providerKey = "menuBarProvider"

    private let defaults: UserDefaults

    // Written back on every change so the choice survives a restart.
    @Published var provider: MenuBarProvider {
        didSet { defaults.set(provider.rawValue, forKey: Self.providerKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.providerKey)
        provider = stored.flatMap(MenuBarProvider.init(rawValue:)) ?? .codex
    }
}
