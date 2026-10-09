import Foundation
import Observation

@MainActor
@Observable
final class VisibleSurfaceClock {
    private(set) var now: Date
    private var task: Task<Void, Never>?
    var isRunning: Bool { task != nil }

    init(now: Date = .now) {
        self.now = now
    }

    func start() {
        guard task == nil else { return }
        now = .now
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                self?.now = .now
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

}
