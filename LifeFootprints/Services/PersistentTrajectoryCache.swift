import Foundation

/// 可删除、可重建的派生缓存。Raw SwiftData 永远是唯一事实来源。
///
/// 文件只存一份 canonical point geometry；trajectory segment 与 resolver point
/// 通过下标引用，避免把 623k 点的坐标和字符串重复序列化两次。
final class PersistentTrajectoryCache: @unchecked Sendable {
    static let shared = PersistentTrajectoryCache(fileURL: defaultURL())
    static let schemaVersion = 1
    static let geometryPresentationVersion = 1

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load(dataRevision: Int) -> TrajectoryResolution? {
        lock.withLock {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                recordMiss("notFound", revision: dataRevision)
                return nil
            }
            do {
                #if DEBUG
                let data = try PerformanceDiagnostics.measure(
                    "PersistentTrajectoryCache.read",
                    metadata: "revision=\(dataRevision)") {
                        try Data(contentsOf: fileURL, options: .mappedIfSafe)
                    }
                let envelope = try PerformanceDiagnostics.measure(
                    "PersistentTrajectoryCache.decode",
                    metadata: "bytes=\(data.count)") {
                        try PropertyListDecoder().decode(Envelope.self, from: data)
                    }
                #else
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                let envelope = try PropertyListDecoder().decode(Envelope.self, from: data)
                #endif
                guard envelope.schemaVersion == Self.schemaVersion else {
                    recordMiss("schema", revision: dataRevision)
                    return nil
                }
                guard envelope.geometryPresentationVersion == Self.geometryPresentationVersion else {
                    recordMiss("geometryPresentation", revision: dataRevision)
                    return nil
                }
                guard envelope.dataRevision == dataRevision else {
                    recordMiss("revision", revision: dataRevision)
                    return nil
                }
                #if DEBUG
                let materialized = PerformanceDiagnostics.measure(
                    "PersistentTrajectoryCache.materialize",
                    metadata: "points=\(envelope.canonicalPoints.count)") {
                        envelope.materialize()
                    }
                guard let resolution = materialized else {
                    recordMiss("invalidReferences", revision: dataRevision)
                    return nil
                }
                PerformanceDiagnostics.event(
                    "PersistentTrajectoryCache.hit",
                    metadata: "revision=\(dataRevision) bytes=\(data.count)")
                PerformanceDiagnostics.count("PersistentTrajectoryCache.hit")
                #else
                guard let resolution = envelope.materialize() else { return nil }
                #endif
                return resolution
            } catch {
                recordMiss("corrupt", revision: dataRevision)
                return nil
            }
        }
    }

    @discardableResult
    func save(_ resolution: TrajectoryResolution, dataRevision: Int) -> Bool {
        lock.withLock {
            do {
                let envelope = Envelope(resolution: resolution, dataRevision: dataRevision)
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                #if DEBUG
                let data = try PerformanceDiagnostics.measure(
                    "PersistentTrajectoryCache.encode",
                    metadata: "points=\(resolution.points.count)") {
                        try encoder.encode(envelope)
                    }
                #else
                let data = try encoder.encode(envelope)
                #endif
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                #if DEBUG
                try PerformanceDiagnostics.measure(
                    "PersistentTrajectoryCache.write",
                    metadata: "revision=\(dataRevision) bytes=\(data.count)") {
                        try data.write(to: fileURL, options: .atomic)
                    }
                PerformanceDiagnostics.event(
                    "PersistentTrajectoryCache.saved",
                    metadata: "revision=\(dataRevision) bytes=\(data.count)")
                PerformanceDiagnostics.count("PersistentTrajectoryCache.saved")
                #else
                try data.write(to: fileURL, options: .atomic)
                #endif
                return true
            } catch {
                #if DEBUG
                PerformanceDiagnostics.event(
                    "PersistentTrajectoryCache.saveFailed",
                    metadata: error.localizedDescription)
                #endif
                return false
            }
        }
    }

    private func recordMiss(_ reason: String, revision: Int) {
        #if DEBUG
        PerformanceDiagnostics.event(
            "PersistentTrajectoryCache.miss",
            metadata: "reason=\(reason) revision=\(revision)")
        PerformanceDiagnostics.count("PersistentTrajectoryCache.miss.\(reason)")
        #endif
    }

    private static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LifeFootprintsDerived", isDirectory: true)
            .appendingPathComponent("trajectory-resolution-v1.plist")
    }
}

private extension PersistentTrajectoryCache {
    struct Envelope: Codable {
        let schemaVersion: Int
        let geometryPresentationVersion: Int
        let dataRevision: Int
        let generatedAt: Date
        let canonicalPoints: [TrajectoryPoint]
        let trajectories: [CachedTrajectory]
        let conflicts: [TrajectoryConflict]
        let resolvedPoints: [CachedResolvedPoint]
        let comparedPairCount: Int

        init(resolution: TrajectoryResolution, dataRevision: Int) {
            var canonicalPoints: [TrajectoryPoint] = []
            var pointIndexByID: [String: Int] = [:]

            func register(_ point: TrajectoryPoint) -> Int {
                if let existing = pointIndexByID[point.id] { return existing }
                let index = canonicalPoints.count
                canonicalPoints.append(point)
                pointIndexByID[point.id] = index
                return index
            }

            self.trajectories = resolution.trajectories.map { trajectory in
                CachedTrajectory(trajectory: trajectory, register: register)
            }
            self.resolvedPoints = resolution.points.map { resolved in
                CachedResolvedPoint(resolved: resolved, pointIndex: register(resolved.point))
            }
            self.schemaVersion = PersistentTrajectoryCache.schemaVersion
            self.geometryPresentationVersion = PersistentTrajectoryCache.geometryPresentationVersion
            self.dataRevision = dataRevision
            self.generatedAt = Date()
            self.canonicalPoints = canonicalPoints
            self.conflicts = resolution.conflicts
            self.comparedPairCount = resolution.comparedPairCount
        }

        func materialize() -> TrajectoryResolution? {
            func point(at index: Int) -> TrajectoryPoint? {
                canonicalPoints.indices.contains(index) ? canonicalPoints[index] : nil
            }
            let materializedTrajectories = trajectories.compactMap {
                $0.materialize(pointAt: point)
            }
            guard materializedTrajectories.count == trajectories.count else { return nil }
            let materializedPoints = resolvedPoints.compactMap {
                $0.materialize(pointAt: point)
            }
            guard materializedPoints.count == resolvedPoints.count else { return nil }
            return TrajectoryResolution(
                trajectories: materializedTrajectories,
                conflicts: conflicts,
                points: materializedPoints,
                comparedPairCount: comparedPairCount)
        }
    }

    struct CachedTrajectory: Codable {
        let id: String
        let source: TrajectorySource
        let sourceIdentifier: String?
        let sessionID: String
        let startTime: Date
        let endTime: Date
        let activityType: String?
        let segments: [CachedSegment]
        let quality: TrajectoryQuality
        let confidence: Double
        let displayPriority: Int

        init(trajectory: Trajectory, register: (TrajectoryPoint) -> Int) {
            id = trajectory.id
            source = trajectory.source
            sourceIdentifier = trajectory.sourceIdentifier
            sessionID = trajectory.sessionID
            startTime = trajectory.startTime
            endTime = trajectory.endTime
            activityType = trajectory.activityType
            segments = trajectory.segments.map { CachedSegment(segment: $0, register: register) }
            quality = trajectory.quality
            confidence = trajectory.confidence
            displayPriority = trajectory.displayPriority
        }

        func materialize(pointAt: (Int) -> TrajectoryPoint?) -> Trajectory? {
            let materializedSegments = segments.compactMap { $0.materialize(pointAt: pointAt) }
            guard materializedSegments.count == segments.count else { return nil }
            return Trajectory(
                id: id, source: source, sourceIdentifier: sourceIdentifier,
                sessionID: sessionID, startTime: startTime, endTime: endTime,
                activityType: activityType, segments: materializedSegments,
                quality: quality, confidence: confidence, displayPriority: displayPriority)
        }
    }

    struct CachedSegment: Codable {
        let id: String
        let trajectoryID: String
        let sessionID: String
        let source: TrajectorySource
        let pointIndices: [Int]
        let startTime: Date
        let endTime: Date
        let quality: TrajectoryQuality

        init(segment: TrajectorySegment, register: (TrajectoryPoint) -> Int) {
            id = segment.id
            trajectoryID = segment.trajectoryID
            sessionID = segment.sessionID
            source = segment.source
            pointIndices = segment.points.map(register)
            startTime = segment.startTime
            endTime = segment.endTime
            quality = segment.quality
        }

        func materialize(pointAt: (Int) -> TrajectoryPoint?) -> TrajectorySegment? {
            let points = pointIndices.compactMap(pointAt)
            guard points.count == pointIndices.count else { return nil }
            return TrajectorySegment(
                id: id, trajectoryID: trajectoryID, sessionID: sessionID,
                source: source, points: points, startTime: startTime,
                endTime: endTime, quality: quality)
        }
    }

    struct CachedResolvedPoint: Codable {
        let trajectoryID: String
        let sessionID: String
        let segmentID: String
        let source: TrajectorySource
        let pointIndex: Int
        let confidence: Double
        let suppressedByTrajectoryID: String?
        let suppressedBySource: TrajectorySource?

        init(resolved: ResolvedTrajectoryPoint, pointIndex: Int) {
            trajectoryID = resolved.trajectoryID
            sessionID = resolved.sessionID
            segmentID = resolved.segmentID
            source = resolved.source
            self.pointIndex = pointIndex
            confidence = resolved.confidence
            suppressedByTrajectoryID = resolved.suppressedByTrajectoryID
            suppressedBySource = resolved.suppressedBySource
        }

        func materialize(pointAt: (Int) -> TrajectoryPoint?) -> ResolvedTrajectoryPoint? {
            guard let point = pointAt(pointIndex) else { return nil }
            return ResolvedTrajectoryPoint(
                trajectoryID: trajectoryID, sessionID: sessionID,
                segmentID: segmentID, source: source, point: point,
                confidence: confidence,
                suppressedByTrajectoryID: suppressedByTrajectoryID,
                suppressedBySource: suppressedBySource)
        }
    }
}
