import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var preferences: MenuBarPreferences
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(action: back) { Label("Back", systemImage: "chevron.left") }
                Spacer()
                Text("Settings").font(.headline)
                Spacer()
            }
            Text("Providers").font(.subheadline.bold())
            ForEach(MenuBarProvider.allCases) { provider in
                Toggle(provider.displayName, isOn: Binding(
                    get: { preferences.enabledProviders.contains(provider) },
                    set: { preferences.setEnabled($0, for: provider) }
                ))
                .toggleStyle(.switch)
            }
            Text("Disabled providers are hidden and their quota refreshes stop. This does not change your accounts or running sessions.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Show Session Runway", isOn: $preferences.showSessionRunway)
                .toggleStyle(.switch)
            Text("Show local session activity below the provider cards.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if let selected = preferences.effectiveProvider {
                Picker("Menu bar shows", selection: Binding(
                    get: { preferences.effectiveProvider ?? selected },
                    set: { preferences.provider = $0 }
                )) {
                    ForEach(preferences.visibleProviders) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
            } else {
                Text("All providers are disabled. The menu bar stays available so you can enable them again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Changes are saved automatically.").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
