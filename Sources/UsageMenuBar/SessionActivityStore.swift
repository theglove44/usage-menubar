import Combine
import Foundation

@MainActor
final class SessionActivityStore: ObservableObject {
    @Published private(set) var snapshot: SessionActivitySnapshot

    private let provider: any SessionActivityProviding
    private let refreshInterval: TimeInterval
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?

    init(
        provider: any SessionActivityProviding = UnavailableSessionActivityProvider(),
        refreshInterval: TimeInterval = 20,
        startImmediately: Bool = true
    ) {
        self.provider = provider
        self.refreshInterval = refreshInterval
        snapshot = provider.snapshot

        guard startImmediately else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        timer?.invalidate()
        refreshTask?.cancel()
    }

    func update(_ snapshot: SessionActivitySnapshot) {
        self.snapshot = snapshot
    }

    func refresh() {
        guard refreshTask == nil else { return }
        let provider = self.provider
        refreshTask = Task { [weak self, provider] in
            let nextSnapshot = await Task.detached(priority: .utility) {
                await provider.discover()
            }.value
            guard let self else { return }
            self.snapshot = nextSnapshot
            self.refreshTask = nil
        }
    }

    // Test and adapter seam for providers that expose a precomputed snapshot.
    func refreshFromProvider() {
        update(provider.snapshot)
    }
}
