import Foundation

/// Coordinates accepted at an external data boundary.
///
/// `.unknown` is intentionally a first-class value: an unverified source must never be
/// converted merely because its numbers happen to fall inside a geographic rectangle.
public enum CoordinateReferenceSystem: String, Codable, CaseIterable, Sendable {
    case unknown
    case wgs84
    case gcj02
}

public struct CoordinateValue: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct CoordinateNormalization: Equatable, Sendable {
    public let raw: CoordinateValue
    public let normalized: CoordinateValue
    public let sourceSystem: CoordinateReferenceSystem
    public let transformVersion: Int?

    public var wasTransformed: Bool { transformVersion != nil }
}

/// Auditable WGS-84 / GCJ-02 transformations used only at declared data boundaries.
///
/// The formula family follows the BSD-licensed `googollee/eviltransform` project. The
/// implementation is kept locally because the app only needs two pure operations and must
/// preserve a stable, testable algorithm version. This is a public approximation, not an
/// authoritative survey transformation; real-world accuracy is established by control points.
public enum CoordinateTransform {
    public static let algorithmVersion = 1

    private static let semiMajorAxis = 6_378_245.0
    private static let eccentricitySquared = 0.006_693_421_622_965_943_23

    /// Coarse applicability bounds used by the referenced public implementation.
    /// The name deliberately avoids implying that this rectangle is an official border.
    public static func isWithinApproximationBounds(latitude: Double,
                                                   longitude: Double) -> Bool {
        longitude >= 72.004 && longitude <= 137.8347
            && latitude >= 0.8293 && latitude <= 55.8271
    }

    public static func wgs84ToGcj02(latitude: Double,
                                    longitude: Double) -> CoordinateValue {
        guard isWithinApproximationBounds(latitude: latitude, longitude: longitude) else {
            return CoordinateValue(latitude: latitude, longitude: longitude)
        }
        let delta = rawDelta(latitude: latitude, longitude: longitude)
        return CoordinateValue(latitude: latitude + delta.latitude,
                               longitude: longitude + delta.longitude)
    }

    /// Numerically inverts the same public forward approximation.
    ///
    /// The tolerance describes formula residual only; it is not a claim about physical GPS or
    /// survey accuracy. A bounded loop keeps malformed inputs from causing unbounded work.
    public static func gcj02ToWgs84(latitude: Double,
                                    longitude: Double,
                                    maximumIterations: Int = 8) -> CoordinateValue {
        guard isWithinApproximationBounds(latitude: latitude, longitude: longitude) else {
            return CoordinateValue(latitude: latitude, longitude: longitude)
        }
        var candidate = CoordinateValue(latitude: latitude, longitude: longitude)
        for _ in 0..<max(1, maximumIterations) {
            let forward = wgs84ToGcj02(latitude: candidate.latitude,
                                       longitude: candidate.longitude)
            let latitudeResidual = latitude - forward.latitude
            let longitudeResidual = longitude - forward.longitude
            candidate = CoordinateValue(latitude: candidate.latitude + latitudeResidual,
                                        longitude: candidate.longitude + longitudeResidual)
            if abs(latitudeResidual) < 1e-9 && abs(longitudeResidual) < 1e-9 { break }
        }
        return candidate
    }

    public static func normalize(latitude: Double, longitude: Double,
                                 sourceSystem: CoordinateReferenceSystem)
        -> CoordinateNormalization {
        let raw = CoordinateValue(latitude: latitude, longitude: longitude)
        switch sourceSystem {
        case .unknown, .wgs84:
            return CoordinateNormalization(raw: raw, normalized: raw,
                                           sourceSystem: sourceSystem,
                                           transformVersion: nil)
        case .gcj02:
            return CoordinateNormalization(
                raw: raw,
                normalized: gcj02ToWgs84(latitude: latitude, longitude: longitude),
                sourceSystem: sourceSystem,
                transformVersion: algorithmVersion)
        }
    }

    private static func rawDelta(latitude: Double, longitude: Double)
        -> CoordinateValue {
        let x = longitude - 105.0
        let y = latitude - 35.0
        var latitudeDelta = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y
            + 0.1 * x * y + 0.2 * sqrt(abs(x))
        latitudeDelta += (20.0 * sin(6.0 * x * .pi)
                          + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        latitudeDelta += (20.0 * sin(y * .pi)
                          + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        latitudeDelta += (160.0 * sin(y / 12.0 * .pi)
                          + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0

        var longitudeDelta = 300.0 + x + 2.0 * y + 0.1 * x * x
            + 0.1 * x * y + 0.1 * sqrt(abs(x))
        longitudeDelta += (20.0 * sin(6.0 * x * .pi)
                           + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        longitudeDelta += (20.0 * sin(x * .pi)
                           + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        longitudeDelta += (150.0 * sin(x / 12.0 * .pi)
                           + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0

        let radians = latitude / 180.0 * .pi
        let sine = sin(radians)
        let magic = 1 - eccentricitySquared * sine * sine
        let squareRoot = sqrt(magic)
        let latitudeDegrees = latitudeDelta * 180.0
            / ((semiMajorAxis * (1 - eccentricitySquared))
               / (magic * squareRoot) * .pi)
        let longitudeDegrees = longitudeDelta * 180.0
            / (semiMajorAxis / squareRoot * cos(radians) * .pi)
        return CoordinateValue(latitude: latitudeDegrees, longitude: longitudeDegrees)
    }
}

/// Converts canonical WGS-84 application data at the map rendering boundary only.
///
/// Apple/AutoNavi map content in mainland China is presented in GCJ-02, while HealthKit,
/// Core Location and the persistent store remain canonical WGS-84. Keeping this policy here
/// prevents display alignment workarounds from leaking into distance, statistics or exports.
public enum MapCoordinatePresentation {
    public static func targetSystem(
        mapType: String,
        customSourceSystem: CoordinateReferenceSystem?
    ) -> CoordinateReferenceSystem {
        if mapType.hasPrefix("custom:") {
            return customSourceSystem == .gcj02 ? .gcj02 : .wgs84
        }
        if mapType == "topographic" { return .wgs84 }
        switch mapType {
        case "standard", "quiet", "satellite": return .gcj02
        default: return .wgs84
        }
    }

    public static func display(
        _ canonical: CoordinateValue,
        targetSystem: CoordinateReferenceSystem
    ) -> CoordinateValue {
        guard targetSystem == .gcj02 else { return canonical }
        return CoordinateTransform.wgs84ToGcj02(
            latitude: canonical.latitude, longitude: canonical.longitude)
    }

    public static func canonical(
        _ displayed: CoordinateValue,
        sourceSystem: CoordinateReferenceSystem
    ) -> CoordinateValue {
        guard sourceSystem == .gcj02 else { return displayed }
        return CoordinateTransform.gcj02ToWgs84(
            latitude: displayed.latitude, longitude: displayed.longitude)
    }
}

public struct TimedCoordinateObservation: Equatable, Sendable {
    public let coordinate: CoordinateValue
    public let timestamp: Date

    public init(latitude: Double, longitude: Double, timestamp: Date) {
        coordinate = CoordinateValue(latitude: latitude, longitude: longitude)
        self.timestamp = timestamp
    }
}

public struct CoordinateSystemDiagnosis: Equatable, Sendable {
    public struct Score: Equatable, Sendable {
        public let system: CoordinateReferenceSystem
        public let medianDistanceMeters: Double
    }

    public let recommendation: CoordinateReferenceSystem?
    public let matchedSampleCount: Int
    public let scores: [Score]

    public var isConclusive: Bool { recommendation != nil }
}

/// Conservative, time-aware diagnosis for an imported route against photo coordinates.
///
/// It never mutates data. A recommendation is returned only when both hypotheses have enough
/// paired evidence and one has a materially lower median distance.
public enum CoordinateSystemDiagnoser {
    public static func diagnose(
        candidates: [TimedCoordinateObservation],
        references: [TimedCoordinateObservation],
        sampleLimit: Int = 160,
        maximumTimeDifference: TimeInterval = 30 * 60
    ) -> CoordinateSystemDiagnosis {
        guard !candidates.isEmpty, !references.isEmpty else {
            return CoordinateSystemDiagnosis(recommendation: nil,
                                             matchedSampleCount: 0, scores: [])
        }
        let sortedReferences = references.sorted { $0.timestamp < $1.timestamp }
        let sampled = evenlySample(candidates, limit: sampleLimit)
        var wgsDistances: [Double] = []
        var gcjDistances: [Double] = []

        for observation in sampled {
            let raw = observation.coordinate
            let asWGS = raw
            let asGCJ = CoordinateTransform.gcj02ToWgs84(
                latitude: raw.latitude, longitude: raw.longitude)
            guard let wgsDistance = nearestDistance(
                to: asWGS, at: observation.timestamp, references: sortedReferences,
                maximumTimeDifference: maximumTimeDifference),
                  let gcjDistance = nearestDistance(
                    to: asGCJ, at: observation.timestamp, references: sortedReferences,
                    maximumTimeDifference: maximumTimeDifference) else { continue }
            wgsDistances.append(wgsDistance)
            gcjDistances.append(gcjDistance)
        }

        let matched = min(wgsDistances.count, gcjDistances.count)
        guard matched >= 5,
              let wgsMedian = median(wgsDistances),
              let gcjMedian = median(gcjDistances) else {
            return CoordinateSystemDiagnosis(recommendation: nil,
                                             matchedSampleCount: matched, scores: [])
        }
        let scores = [
            CoordinateSystemDiagnosis.Score(system: .wgs84,
                                            medianDistanceMeters: wgsMedian),
            CoordinateSystemDiagnosis.Score(system: .gcj02,
                                            medianDistanceMeters: gcjMedian)
        ].sorted { $0.medianDistanceMeters < $1.medianDistanceMeters }
        let best = scores[0]
        let runnerUp = scores[1]
        let improvement = runnerUp.medianDistanceMeters - best.medianDistanceMeters
        let ratio = runnerUp.medianDistanceMeters / max(best.medianDistanceMeters, 1)
        let conclusive = best.medianDistanceMeters <= 200
            && improvement >= 120 && ratio >= 1.5
        return CoordinateSystemDiagnosis(
            recommendation: conclusive ? best.system : nil,
            matchedSampleCount: matched,
            scores: scores)
    }

    private static func evenlySample(_ values: [TimedCoordinateObservation], limit: Int)
        -> [TimedCoordinateObservation] {
        guard limit > 0 else { return [] }
        guard values.count > limit else { return values }
        if limit == 1 { return [values[0]] }
        return (0..<limit).map { index in
            values[index * (values.count - 1) / (limit - 1)]
        }
    }

    private static func nearestDistance(
        to coordinate: CoordinateValue,
        at timestamp: Date,
        references: [TimedCoordinateObservation],
        maximumTimeDifference: TimeInterval
    ) -> Double? {
        let lowerTime = timestamp.addingTimeInterval(-maximumTimeDifference)
        let upperTime = timestamp.addingTimeInterval(maximumTimeDifference)
        var low = 0
        var high = references.count
        while low < high {
            let middle = (low + high) / 2
            if references[middle].timestamp < lowerTime { low = middle + 1 }
            else { high = middle }
        }
        var index = low
        var best = Double.infinity
        while index < references.count, references[index].timestamp <= upperTime {
            let reference = references[index].coordinate
            best = min(best, distanceMeters(from: coordinate, to: reference))
            index += 1
        }
        return best.isFinite ? best : nil
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func distanceMeters(from lhs: CoordinateValue,
                                       to rhs: CoordinateValue) -> Double {
        let earthRadius = 6_371_000.0
        let latitude1 = lhs.latitude * .pi / 180
        let latitude2 = rhs.latitude * .pi / 180
        let latitudeDelta = (rhs.latitude - lhs.latitude) * .pi / 180
        let longitudeDelta = (rhs.longitude - lhs.longitude) * .pi / 180
        let rawA = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(latitude1) * cos(latitude2)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        let a = min(1, max(0, rawA))
        return earthRadius * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}
