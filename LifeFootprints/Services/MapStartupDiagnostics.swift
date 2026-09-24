import Foundation

extension Notification.Name {
    static let mapDisplayPreviewReady = Notification.Name("mapDisplayPreviewReady")
}

enum MapStartupMilestone: String, Codable, CaseIterable {
    case processStarted, mapShellReady, cachedContentReady
    case visibleRegionFresh, photoLayerReady, backgroundRefreshComplete
}

/// Times are relative to entry into App.init, not operating-system process creation.
final class MapStartupDiagnostics: @unchecked Sendable {
    static let shared = MapStartupDiagnostics()
    private let clock = ContinuousClock()
    private let lock = NSLock()
    private var origin: ContinuousClock.Instant?
    private var milestones: [String: Double] = [:]

    func mark(_ milestone: MapStartupMilestone) {
        lock.withLock {
            let now = clock.now
            if origin == nil { origin = now }
            guard milestones[milestone.rawValue] == nil, let origin else { return }
            let elapsed = origin.duration(to: now).components
            milestones[milestone.rawValue] = Double(elapsed.seconds) * 1_000
                + Double(elapsed.attoseconds) / 1e15
        }
        #if DEBUG
        PerformanceDiagnostics.event("MapStartup.\(milestone.rawValue)")
        #endif
    }

    func snapshot() -> [String: Double] { lock.withLock { milestones } }
}
