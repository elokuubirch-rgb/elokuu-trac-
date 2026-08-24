import Foundation

public enum TrajectorySource: String, Codable, Sendable {
    case coreLocation
    case healthWorkout
    case imported
    case inferred
}

public struct TrajectoryPoint: Codable, Equatable, Sendable {
    public let id: String
    public let latitude: Double
    public let longitude: Double
    public let timestamp: Date
    public let altitude: Double?
    public let horizontalAccuracy: Double?
    public let speed: Double?
    public let course: Double?
    public let source: TrajectorySource

    public init(id: String, latitude: Double, longitude: Double, timestamp: Date,
                altitude: Double? = nil, horizontalAccuracy: Double? = nil,
                speed: Double? = nil, course: Double? = nil, source: TrajectorySource) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.course = course
        self.source = source
    }
}

public struct TrajectoryQuality: Codable, Equatable, Sendable {
    public let pointCount: Int
    public let duration: TimeInterval
    public let maximumGap: TimeInterval
    public let accuratePointRatio: Double
    public let confidence: Double

    public init(pointCount: Int, duration: TimeInterval, maximumGap: TimeInterval,
                accuratePointRatio: Double, confidence: Double) {
        self.pointCount = pointCount
        self.duration = duration
        self.maximumGap = maximumGap
        self.accuratePointRatio = accuratePointRatio
        self.confidence = confidence
    }
}

public struct TrajectorySegment: Equatable, Sendable {
    public let id: String
    public let trajectoryID: String
    public let sessionID: String
    public let source: TrajectorySource
    public let points: [TrajectoryPoint]
    public let startTime: Date
    public let endTime: Date
    public let quality: TrajectoryQuality

    public init(id: String, trajectoryID: String, sessionID: String,
                source: TrajectorySource, points: [TrajectoryPoint],
                startTime: Date, endTime: Date, quality: TrajectoryQuality) {
        self.id = id
        self.trajectoryID = trajectoryID
        self.sessionID = sessionID
        self.source = source
        self.points = points
        self.startTime = startTime
        self.endTime = endTime
        self.quality = quality
    }
}

public struct Trajectory: Equatable, Sendable {
    public let id: String
    public let source: TrajectorySource
    public let sourceIdentifier: String?
    public let sessionID: String
    public let startTime: Date
    public let endTime: Date
    public let activityType: String?
    public let segments: [TrajectorySegment]
    public let quality: TrajectoryQuality
    public let confidence: Double
    public let displayPriority: Int

    public init(id: String, source: TrajectorySource, sourceIdentifier: String?,
                sessionID: String, startTime: Date, endTime: Date,
                activityType: String?, segments: [TrajectorySegment],
                quality: TrajectoryQuality, confidence: Double, displayPriority: Int) {
        self.id = id
        self.source = source
        self.sourceIdentifier = sourceIdentifier
        self.sessionID = sessionID
        self.startTime = startTime
        self.endTime = endTime
        self.activityType = activityType
        self.segments = segments
        self.quality = quality
        self.confidence = confidence
        self.displayPriority = displayPriority
    }
}

/// Repository 与领域 Builder 之间的值类型边界；不暴露 SwiftData Model。
public struct TrajectorySample: Equatable, Sendable {
    public let id: String
    public let source: TrajectorySource
    public let sourceIdentifier: String?
    public let sessionID: String?
    public let routeID: String?
    public let activityType: String?
    public let latitude: Double
    public let longitude: Double
    public let timestamp: Date
    public let altitude: Double?
    public let horizontalAccuracy: Double?
    public let speed: Double?
    public let course: Double?

    public init(id: String, source: TrajectorySource, sourceIdentifier: String? = nil,
                sessionID: String? = nil, routeID: String? = nil, activityType: String? = nil,
                latitude: Double, longitude: Double, timestamp: Date,
                altitude: Double? = nil, horizontalAccuracy: Double? = nil,
                speed: Double? = nil, course: Double? = nil) {
        self.id = id
        self.source = source
        self.sourceIdentifier = sourceIdentifier
        self.sessionID = sessionID
        self.routeID = routeID
        self.activityType = activityType
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.course = course
    }
}

public struct TrajectoryBuilderConfiguration: Equatable, Sendable {
    public var maximumTimeGap: TimeInterval
    public var maximumDistanceGapMeters: Double
    public var acceptableHorizontalAccuracy: Double

    public init(maximumTimeGap: TimeInterval = 45 * 60,
                maximumDistanceGapMeters: Double = 3_000,
                acceptableHorizontalAccuracy: Double = 100) {
        self.maximumTimeGap = maximumTimeGap
        self.maximumDistanceGapMeters = maximumDistanceGapMeters
        self.acceptableHorizontalAccuracy = acceptableHorizontalAccuracy
    }
}

public enum TrajectoryBuilder {
    public static func build(samples: [TrajectorySample],
                             configuration: TrajectoryBuilderConfiguration = .init()) -> [Trajectory] {
        let valid = samples.filter {
            GeoMath.isValid(latitude: $0.latitude, longitude: $0.longitude)
        }
        let groupedBySource = Dictionary(grouping: valid, by: \.source)
        var trajectories: [Trajectory] = []

        for source in TrajectorySource.allBuilderSources {
            let sourceSamples = groupedBySource[source] ?? []
            switch source {
            case .healthWorkout:
                trajectories += buildHealth(samples: sourceSamples, configuration: configuration)
            case .coreLocation, .imported:
                trajectories += buildGapDelimited(samples: sourceSamples, source: source,
                                                   configuration: configuration)
            case .inferred:
                continue
            }
        }
        return trajectories.sorted { $0.startTime < $1.startTime }
    }

    private static func buildHealth(samples: [TrajectorySample],
                                    configuration: TrajectoryBuilderConfiguration) -> [Trajectory] {
        let sessions = Dictionary(grouping: samples) { sample in
            sample.sessionID ?? sample.sourceIdentifier ?? "health-unknown"
        }
        return sessions.keys.sorted().compactMap { sessionID in
            let sessionSamples = sessions[sessionID] ?? []
            let routes = Dictionary(grouping: sessionSamples) {
                $0.routeID ?? "legacy-route:\(sessionID)"
            }
            var segmentSamples: [(id: String, samples: [TrajectorySample])] = []
            for routeID in routes.keys.sorted() {
                let partitions = partition(routes[routeID] ?? [], configuration: configuration)
                for (index, points) in partitions.enumerated() {
                    segmentSamples.append(("\(routeID):segment:\(index)", points))
                }
            }
            return makeTrajectory(source: .healthWorkout, sessionID: sessionID,
                                  sourceIdentifier: sessionID,
                                  activityType: sessionSamples.first?.activityType,
                                  segmentSamples: segmentSamples,
                                  configuration: configuration)
        }
    }

    private static func buildGapDelimited(samples: [TrajectorySample], source: TrajectorySource,
                                          configuration: TrajectoryBuilderConfiguration) -> [Trajectory] {
        var result: [Trajectory] = []
        let explicit = Dictionary(grouping: samples.filter { $0.sessionID != nil }) { $0.sessionID! }
        for sessionID in explicit.keys.sorted() {
            let sessionSamples = explicit[sessionID] ?? []
            let segments = partition(sessionSamples, configuration: configuration).enumerated().map {
                ("\(sessionID):segment:\($0.offset)", $0.element)
            }
            if let trajectory = makeTrajectory(
                source: source, sessionID: sessionID,
                sourceIdentifier: sessionSamples.first?.sourceIdentifier,
                activityType: sessionSamples.first?.activityType,
                segmentSamples: segments, configuration: configuration) {
                result.append(trajectory)
            }
        }
        let derived = partition(samples.filter { $0.sessionID == nil }, configuration: configuration)
        for points in derived {
            guard let first = points.first else { continue }
            let sessionID = "\(source.rawValue):\(millis(first.timestamp))"
            if let trajectory = makeTrajectory(
                source: source, sessionID: sessionID,
                sourceIdentifier: first.sourceIdentifier, activityType: first.activityType,
                segmentSamples: [("\(sessionID):segment:0", points)],
                configuration: configuration) {
                result.append(trajectory)
            }
        }
        return result
    }

    private static func partition(_ samples: [TrajectorySample],
                                  configuration: TrajectoryBuilderConfiguration) -> [[TrajectorySample]] {
        let ordered = samples.sorted {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
        }
        var result: [[TrajectorySample]] = []
        var current: [TrajectorySample] = []
        for sample in ordered {
            if let previous = current.last {
                let timeGap = sample.timestamp.timeIntervalSince(previous.timestamp)
                let distance = GeoMath.distanceMeters(
                    from: (previous.latitude, previous.longitude),
                    to: (sample.latitude, sample.longitude))
                if timeGap > configuration.maximumTimeGap || distance > configuration.maximumDistanceGapMeters {
                    if !current.isEmpty { result.append(current) }
                    current = []
                }
            }
            current.append(sample)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func makeTrajectory(source: TrajectorySource, sessionID: String,
                                       sourceIdentifier: String?, activityType: String?,
                                       segmentSamples: [(id: String, samples: [TrajectorySample])],
                                       configuration: TrajectoryBuilderConfiguration) -> Trajectory? {
        let all = segmentSamples.flatMap(\.samples).sorted { $0.timestamp < $1.timestamp }
        guard let first = all.first, let last = all.last else { return nil }
        let trajectoryID = "\(source.rawValue):\(sessionID)"
        let segments = segmentSamples.compactMap { entry -> TrajectorySegment? in
            guard let start = entry.samples.first?.timestamp,
                  let end = entry.samples.last?.timestamp else { return nil }
            let points = entry.samples.map(makePoint)
            return TrajectorySegment(
                id: "\(trajectoryID):\(entry.id)", trajectoryID: trajectoryID,
                sessionID: sessionID, source: source, points: points,
                startTime: start, endTime: end,
                quality: quality(of: entry.samples, configuration: configuration))
        }
        let trajectoryQuality = quality(of: all, configuration: configuration)
        return Trajectory(
            id: trajectoryID, source: source, sourceIdentifier: sourceIdentifier,
            sessionID: sessionID, startTime: first.timestamp, endTime: last.timestamp,
            activityType: activityType, segments: segments, quality: trajectoryQuality,
            confidence: trajectoryQuality.confidence,
            displayPriority: source == .healthWorkout ? 200 : 100)
    }

    private static func makePoint(_ sample: TrajectorySample) -> TrajectoryPoint {
        TrajectoryPoint(id: sample.id, latitude: sample.latitude, longitude: sample.longitude,
                        timestamp: sample.timestamp, altitude: sample.altitude,
                        horizontalAccuracy: sample.horizontalAccuracy, speed: sample.speed,
                        course: sample.course, source: sample.source)
    }

    private static func quality(of samples: [TrajectorySample],
                                configuration: TrajectoryBuilderConfiguration) -> TrajectoryQuality {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        let duration = max(0, (ordered.last?.timestamp ?? .distantPast)
            .timeIntervalSince(ordered.first?.timestamp ?? .distantPast))
        var maximumGap: TimeInterval = 0
        for pair in zip(ordered, ordered.dropFirst()) {
            maximumGap = max(maximumGap, pair.1.timestamp.timeIntervalSince(pair.0.timestamp))
        }
        let measured = ordered.compactMap(\.horizontalAccuracy).filter { $0 >= 0 }
        let accurateRatio = measured.isEmpty ? 0.5 :
            Double(measured.filter { $0 <= configuration.acceptableHorizontalAccuracy }.count) / Double(measured.count)
        let pointScore = min(1, Double(ordered.count) / 20)
        let confidence = min(1, max(0, pointScore * 0.55 + accurateRatio * 0.45))
        return TrajectoryQuality(pointCount: ordered.count, duration: duration,
                                 maximumGap: maximumGap, accuratePointRatio: accurateRatio,
                                 confidence: confidence)
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

private extension TrajectorySource {
    static let allBuilderSources: [TrajectorySource] = [.coreLocation, .healthWorkout, .imported, .inferred]
}
