import Foundation
import SwiftUI

// Which single provider the menu bar shows. The dropdown still lists every
// provider; this only controls the always-visible gauge in the menu bar.
enum MenuBarProvider: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case grok

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
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

    @Published private(set) var enabledProviders: Set<MenuBarProvider> {
        didSet { defaults.set(enabledProviders.map(\.rawValue).sorted(), forKey: "enabledProviders") }
    }

    @Published var showSessionRunway: Bool {
        didSet { defaults.set(showSessionRunway, forKey: "showSessionRunway") }
    }

    var visibleProviders: [MenuBarProvider] {
        MenuBarProvider.allCases.filter { enabledProviders.contains($0) }
    }

    var effectiveProvider: MenuBarProvider? {
        enabledProviders.contains(provider) ? provider : visibleProviders.first
    }

    func setEnabled(_ enabled: Bool, for provider: MenuBarProvider) {
        if enabled { enabledProviders.insert(provider) }
        else { enabledProviders.remove(provider) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.providerKey)
        provider = stored.flatMap(MenuBarProvider.init(rawValue:)) ?? .codex
        enabledProviders = defaults.stringArray(forKey: "enabledProviders")
            .map { Set($0.compactMap(MenuBarProvider.init(rawValue:))) }
            ?? Set(MenuBarProvider.allCases)
        showSessionRunway = defaults.object(forKey: "showSessionRunway") as? Bool ?? true
    }
}
