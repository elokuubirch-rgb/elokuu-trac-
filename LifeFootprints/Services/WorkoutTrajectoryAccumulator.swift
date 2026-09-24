import Foundation

/// SwiftData batch 与轨迹领域之间的轻量值，确保 @Model 生命周期止于单个 fetch page。
struct WorkoutRoutePointValue {
    let workoutID: String
    let routeID: String?
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestamp: Date
    let horizontalAccuracy: Double?
    let speed: Double?
    let course: Double?
}

/// 每个 Route 的输入必须按 timestamp 升序。它直接构造最终 TrajectoryPoint，避免
/// 同时常驻 SwiftData models + TrajectorySample + TrajectoryPoint 三份对象。
final class WorkoutTrajectoryAccumulator {
    private let configuration: TrajectoryBuilderConfiguration
    private let activityByWorkout: [String: String]
    private let collectsPoints: Bool
    private var sessions: [String: SessionState] = [:]
    private(set) var acceptedSampleCount = 0

    init(activityByWorkout: [String: String],
         configuration: TrajectoryBuilderConfiguration = .init(),
         collectsPoints: Bool = true) {
        self.activityByWorkout = activityByWorkout
        self.configuration = configuration
        self.collectsPoints = collectsPoints
    }

    func append(_ value: WorkoutRoutePointValue, globalIndex: Int) {
        guard GeoMath.isValid(latitude: value.latitude, longitude: value.longitude) else { return }
        let session = sessions[value.workoutID]
            ?? SessionState(id: value.workoutID, activityType: activityByWorkout[value.workoutID])
        sessions[value.workoutID] = session
        let routeID = value.routeID ?? "legacy-route:\(value.workoutID)"
        let route = session.routes[routeID] ?? RouteState()
        session.routes[routeID] = route
        acceptedSampleCount += 1
        guard collectsPoints else { return }
        let point = TrajectoryPoint(
            // globalIndex 在既有实现中已是读取顺序衍生值，不是持久业务 ID。
            // 短 ASCII ID 进入 Swift small-string 内联存储，避免 170 万次堆分配。
            id: "w:\(globalIndex)",
            latitude: value.latitude, longitude: value.longitude,
            timestamp: value.timestamp, altitude: value.altitude,
            horizontalAccuracy: value.horizontalAccuracy,
            speed: value.speed, course: value.course, source: .healthWorkout)

        if let previous = route.segments.last?.points.last {
            let timeGap = point.timestamp.timeIntervalSince(previous.timestamp)
            let distance = GeoMath.distanceMeters(
                from: (previous.latitude, previous.longitude),
                to: (point.latitude, point.longitude))
            if timeGap > configuration.maximumTimeGap
                || distance > configuration.maximumDistanceGapMeters {
                route.segments.append(SegmentState())
            }
        }
        if route.segments.isEmpty { route.segments.append(SegmentState()) }
        route.segments[route.segments.count - 1].append(
            point, acceptableAccuracy: configuration.acceptableHorizontalAccuracy)
    }

    func finish() -> [Trajectory] {
        sessions.keys.sorted().compactMap { sessionID in
            guard let session = sessions[sessionID] else { return nil }
            let sessionStats = mergedStats(for: session)
            guard let start = sessionStats.firstTime,
                  let end = sessionStats.lastTime else { return nil }
            let trajectoryID = "\(TrajectorySource.healthWorkout.rawValue):\(sessionID)"
            var segments: [TrajectorySegment] = []
            for routeID in session.routes.keys.sorted() {
                guard let route = session.routes[routeID] else { continue }
                for (index, state) in route.segments.enumerated() {
                    guard let segmentStart = state.stats.firstTime,
                          let segmentEnd = state.stats.lastTime else { continue }
                    segments.append(TrajectorySegment(
                        id: "\(trajectoryID):\(routeID):segment:\(index)",
                        trajectoryID: trajectoryID, sessionID: sessionID,
                        source: .healthWorkout, points: state.points,
                        startTime: segmentStart, endTime: segmentEnd,
                        quality: state.stats.quality(configuration: configuration)))
                }
            }
            let quality = sessionStats.quality(configuration: configuration)
            return Trajectory(
                id: trajectoryID, source: .healthWorkout,
                sourceIdentifier: sessionID, sessionID: sessionID,
                startTime: start, endTime: end, activityType: session.activityType,
                segments: segments, quality: quality, confidence: quality.confidence,
                displayPriority: 200)
        }.sorted { $0.startTime < $1.startTime }
    }

    /// Route 分批读取后用 k-way merge 恢复 Session 的全局时间顺序；质量、起止
    /// 时间和 maximumGap 与一次全库 timestamp 排序完全一致，额外内存只与
    /// Segment 数量相关。
    private func mergedStats(for session: SessionState) -> PointStats {
        let sequences = session.routes.keys.sorted().flatMap { routeID in
            session.routes[routeID]?.segments.map(\.points) ?? []
        }.filter { !$0.isEmpty }
        struct Cursor {
            let sequence: Int
            let point: Int
        }
        func precedes(_ left: Cursor, _ right: Cursor) -> Bool {
            let lhs = sequences[left.sequence][left.point]
            let rhs = sequences[right.sequence][right.point]
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id < rhs.id
        }
        var heap: [Cursor] = []
        func push(_ cursor: Cursor) {
            heap.append(cursor)
            var index = heap.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard precedes(heap[index], heap[parent]) else { break }
                heap.swapAt(index, parent)
                index = parent
            }
        }
        func pop() -> Cursor? {
            guard !heap.isEmpty else { return nil }
            if heap.count == 1 { return heap.removeLast() }
            let result = heap[0]
            heap[0] = heap.removeLast()
            var index = 0
            while true {
                let left = index * 2 + 1
                guard left < heap.count else { break }
                let right = left + 1
                let child = right < heap.count && precedes(heap[right], heap[left])
                    ? right : left
                guard precedes(heap[child], heap[index]) else { break }
                heap.swapAt(index, child)
                index = child
            }
            return result
        }
        for index in sequences.indices { push(Cursor(sequence: index, point: 0)) }
        var stats = PointStats()
        while let cursor = pop() {
            let point = sequences[cursor.sequence][cursor.point]
            stats.append(point, acceptableAccuracy: configuration.acceptableHorizontalAccuracy)
            let next = cursor.point + 1
            if next < sequences[cursor.sequence].count {
                push(Cursor(sequence: cursor.sequence, point: next))
            }
        }
        return stats
    }

    private final class SessionState {
        let id: String
        let activityType: String?
        var routes: [String: RouteState] = [:]
        init(id: String, activityType: String?) {
            self.id = id
            self.activityType = activityType
        }
    }

    private final class RouteState {
        var segments: [SegmentState] = []
    }

    private final class SegmentState {
        var points: [TrajectoryPoint] = []
        var stats = PointStats()
        func append(_ point: TrajectoryPoint, acceptableAccuracy: Double) {
            points.append(point)
            stats.append(point, acceptableAccuracy: acceptableAccuracy)
        }
    }

    private struct PointStats {
        var count = 0
        var firstTime: Date?
        var lastTime: Date?
        var maximumGap: TimeInterval = 0
        var measuredAccuracyCount = 0
        var accuratePointCount = 0

        mutating func append(_ point: TrajectoryPoint, acceptableAccuracy: Double) {
            if let lastTime {
                maximumGap = max(maximumGap, point.timestamp.timeIntervalSince(lastTime))
            } else {
                firstTime = point.timestamp
            }
            lastTime = point.timestamp
            count += 1
            if let accuracy = point.horizontalAccuracy, accuracy >= 0 {
                measuredAccuracyCount += 1
                if accuracy <= acceptableAccuracy { accuratePointCount += 1 }
            }
        }

        func quality(configuration: TrajectoryBuilderConfiguration) -> TrajectoryQuality {
            let ratio = measuredAccuracyCount == 0 ? 0.5
                : Double(accuratePointCount) / Double(measuredAccuracyCount)
            let pointScore = min(1, Double(count) / 20)
            let confidence = min(1, max(0, pointScore * 0.55 + ratio * 0.45))
            return TrajectoryQuality(
                pointCount: count,
                duration: max(0, (lastTime ?? .distantPast)
                    .timeIntervalSince(firstTime ?? .distantPast)),
                maximumGap: maximumGap, accuratePointRatio: ratio,
                confidence: confidence)
        }
    }

}

// MARK: - Route point chunk storage prototype

/// 只用于验证未来 SwiftData row -> compact chunk 的空间与读取收益；尚未接入生产模型。
/// 经纬度使用 1e-7 度、时间使用毫秒，其余测量值使用厘米级定点数后 delta/varint。
struct RoutePointChunkPrototypeSample: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestamp: Date
    let horizontalAccuracy: Double?
    let speed: Double?
    let course: Double?
}

struct RoutePointChunkPrototypeDecoded: Equatable, Sendable {
    let workoutID: String
    let routeID: String?
    let segmentID: String
    let samples: [RoutePointChunkPrototypeSample]
}

enum RoutePointChunkPrototypeCodec {
    private static let magic = Array("LFRPC1\0\0".utf8)
    private static let maximumPointCount = 5_000_000

    static func encode(workoutID: String, routeID: String?, segmentID: String,
                       samples: [RoutePointChunkPrototypeSample]) throws -> Data {
        guard samples.count <= maximumPointCount else { throw CodecError.invalid }
        var writer = RouteChunkWriter(capacity: max(128, samples.count * 24))
        writer.append(bytes: magic)
        writer.append(UInt32(1))
        try writer.append(workoutID)
        try writer.appendOptional(routeID)
        try writer.append(segmentID)
        try writer.appendCount(samples.count)
        var previousLatitude: Int64 = 0
        var previousLongitude: Int64 = 0
        var previousTimestamp: Int64 = 0
        for sample in samples {
            guard sample.latitude.isFinite, sample.longitude.isFinite,
                  sample.altitude.isFinite, sample.timestamp.timeIntervalSince1970.isFinite
            else { throw CodecError.invalid }
            let latitude = try fixed(sample.latitude, scale: 10_000_000)
            let longitude = try fixed(sample.longitude, scale: 10_000_000)
            let timestamp = try fixed(sample.timestamp.timeIntervalSince1970, scale: 1_000)
            for (value, previous) in [(latitude, previousLatitude),
                                      (longitude, previousLongitude),
                                      (timestamp, previousTimestamp)] {
                let delta = value.subtractingReportingOverflow(previous)
                guard !delta.overflow else { throw CodecError.invalid }
                writer.appendSigned(delta.partialValue)
            }
            try writer.appendOptionalFixed(sample.altitude, scale: 100)
            try writer.appendOptionalFixed(sample.horizontalAccuracy, scale: 100)
            try writer.appendOptionalFixed(sample.speed, scale: 100)
            try writer.appendOptionalFixed(sample.course, scale: 100)
            previousLatitude = latitude
            previousLongitude = longitude
            previousTimestamp = timestamp
        }
        return writer.data
    }

    static func decode(_ data: Data) throws -> RoutePointChunkPrototypeDecoded {
        var reader = RouteChunkReader(data: data)
        guard try reader.readBytes(count: magic.count) == magic,
              try reader.readUInt32() == 1 else { throw CodecError.invalid }
        let workoutID = try reader.readString()
        let routeID = try reader.readOptionalString()
        let segmentID = try reader.readString()
        let count = try reader.readCount(maximum: maximumPointCount)
        var samples: [RoutePointChunkPrototypeSample] = []
        samples.reserveCapacity(count)
        var latitude: Int64 = 0
        var longitude: Int64 = 0
        var timestamp: Int64 = 0
        for _ in 0..<count {
            latitude = try adding(latitude, reader.readSigned())
            longitude = try adding(longitude, reader.readSigned())
            timestamp = try adding(timestamp, reader.readSigned())
            samples.append(RoutePointChunkPrototypeSample(
                latitude: Double(latitude) / 10_000_000,
                longitude: Double(longitude) / 10_000_000,
                altitude: try reader.readOptionalFixed(scale: 100) ?? 0,
                timestamp: Date(timeIntervalSince1970: Double(timestamp) / 1_000),
                horizontalAccuracy: try reader.readOptionalFixed(scale: 100),
                speed: try reader.readOptionalFixed(scale: 100),
                course: try reader.readOptionalFixed(scale: 100)))
        }
        guard reader.isAtEnd else { throw CodecError.invalid }
        return RoutePointChunkPrototypeDecoded(
            workoutID: workoutID, routeID: routeID,
            segmentID: segmentID, samples: samples)
    }

    enum CodecError: Error { case invalid }

    fileprivate static func fixed(_ value: Double, scale: Double) throws -> Int64 {
        guard let result = Int64(exactly: (value * scale).rounded()) else {
            throw CodecError.invalid
        }
        return result
    }

    private static func adding(_ value: Int64, _ delta: Int64) throws -> Int64 {
        let result = value.addingReportingOverflow(delta)
        guard !result.overflow else { throw CodecError.invalid }
        return result.partialValue
    }
}

private struct RouteChunkWriter {
    private(set) var data = Data()

    init(capacity: Int) { data.reserveCapacity(capacity) }

    mutating func append(bytes: [UInt8]) { data.append(contentsOf: bytes) }

    mutating func append<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func appendCount(_ count: Int) throws {
        guard count >= 0, count <= Int(UInt32.max) else {
            throw RoutePointChunkPrototypeCodec.CodecError.invalid
        }
        append(UInt32(count))
    }

    mutating func append(_ string: String) throws {
        let bytes = Array(string.utf8)
        try appendCount(bytes.count)
        data.append(contentsOf: bytes)
    }

    mutating func appendOptional(_ string: String?) throws {
        guard let string else {
            data.append(0)
            return
        }
        data.append(1)
        try append(string)
    }

    mutating func appendSigned(_ value: Int64) {
        let zigZag = UInt64(bitPattern: (value << 1) ^ (value >> 63))
        appendVarint(zigZag)
    }

    mutating func appendOptionalFixed(_ value: Double?, scale: Double) throws {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        appendSigned(try RoutePointChunkPrototypeCodec.fixed(value, scale: scale))
    }

    private mutating func appendVarint(_ value: UInt64) {
        var remainder = value
        while remainder >= 0x80 {
            data.append(UInt8(remainder & 0x7f) | 0x80)
            remainder >>= 7
        }
        data.append(UInt8(remainder))
    }
}

private struct RouteChunkReader {
    let data: Data
    private(set) var offset = 0
    var isAtEnd: Bool { offset == data.count }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset <= data.count - count else {
            throw RoutePointChunkPrototypeCodec.CodecError.invalid
        }
        defer { offset += count }
        return Array(data[offset..<(offset + count)])
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        return bytes.enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
    }

    mutating func readCount(maximum: Int) throws -> Int {
        let count = Int(try readUInt32())
        guard count <= maximum else {
            throw RoutePointChunkPrototypeCodec.CodecError.invalid
        }
        return count
    }

    mutating func readString() throws -> String {
        let count = try readCount(maximum: 1_048_576)
        guard let value = String(bytes: try readBytes(count: count), encoding: .utf8)
        else { throw RoutePointChunkPrototypeCodec.CodecError.invalid }
        return value
    }

    mutating func readOptionalString() throws -> String? {
        let tag = try readByte()
        if tag == 0 { return nil }
        guard tag == 1 else { throw RoutePointChunkPrototypeCodec.CodecError.invalid }
        return try readString()
    }

    mutating func readSigned() throws -> Int64 {
        let value = try readVarint()
        return Int64(bitPattern: (value >> 1) ^ (0 &- (value & 1)))
    }

    mutating func readOptionalFixed(scale: Double) throws -> Double? {
        let tag = try readByte()
        if tag == 0 { return nil }
        guard tag == 1 else { throw RoutePointChunkPrototypeCodec.CodecError.invalid }
        return Double(try readSigned()) / scale
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < data.count else {
            throw RoutePointChunkPrototypeCodec.CodecError.invalid
        }
        defer { offset += 1 }
        return data[offset]
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            let byte = try readByte()
            guard shift < 63 || byte <= 1 else {
                throw RoutePointChunkPrototypeCodec.CodecError.invalid
            }
            result |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 { return result }
        }
        throw RoutePointChunkPrototypeCodec.CodecError.invalid
    }
}
