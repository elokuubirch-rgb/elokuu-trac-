import Foundation

struct PhotoTrajectoryAssociationRecord: Codable, Equatable {
    let photoID: String
    let photoFingerprint: String
    let kind: String
    let lat: Double
    let lon: Double
    let trajectoryID: String?
    let sessionID: String?
    let segmentID: String?
    let source: String?
    let confidence: Double
    let distance: Double?
    let timeDelta: TimeInterval?

    init(photo: PhotoRecord, result: TrailSnapResult) {
        photoID = photo.localIdentifier
        photoFingerprint = Self.fingerprint(photo)
        switch result.kind {
        case .exact: kind = "exact"
        case .snapped: kind = "snapped"
        case .interpolated: kind = "interpolated"
        case .kept: kind = "kept"
        }
        lat = result.lat; lon = result.lon
        trajectoryID = result.trajectoryID; sessionID = result.sessionID
        segmentID = result.segmentID; source = result.source?.rawValue
        confidence = result.confidence; distance = result.distance
        timeDelta = result.timeDelta
    }

    var result: TrailSnapResult? {
        let matchKind: TrailMatchKind
        switch kind {
        case "exact": matchKind = .exact
        case "snapped": matchKind = .snapped
        case "interpolated": matchKind = .interpolated
        case "kept": matchKind = .kept
        default: return nil
        }
        guard lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180,
              confidence.isFinite, (0...1).contains(confidence) else { return nil }
        return TrailSnapResult(kind: matchKind, lat: lat, lon: lon,
            trajectoryID: trajectoryID, sessionID: sessionID, segmentID: segmentID,
            source: source.flatMap(TrajectorySource.init(rawValue:)),
            confidence: confidence, distance: distance, timeDelta: timeDelta)
    }

    static func fingerprint(_ photo: PhotoRecord) -> String {
        "\(photo.latitude.bitPattern):\(photo.longitude.bitPattern):\(photo.timestamp.timeIntervalSince1970.bitPattern)"
    }
}

final class PhotoTrajectoryAssociationStore: @unchecked Sendable {
    struct Lookup {
        let matches: [String: TrailSnapResult]
        let reusableRecords: [String: PhotoTrajectoryAssociationRecord]
        let missingPhotoIDs: Set<String>
    }

    private struct Envelope: Codable {
        let schema: Int
        let geometryPolicy: Int
        let displaySafetyRevision: Int
        let records: [PhotoTrajectoryAssociationRecord]
    }

    static let shared = PhotoTrajectoryAssociationStore(url: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("photo-trajectory-associations-v1.plist"))
    private static let maximumBytes = 32 * 1_024 * 1_024
    private let url: URL
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    func lookup(photos: [PhotoRecord], safetyRevision: Int) -> Lookup {
        lock.withLock {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= Self.maximumBytes,
                  let data = try? Data(contentsOf: url),
                  let envelope = try? PropertyListDecoder().decode(Envelope.self, from: data),
                  envelope.schema == 1,
                  envelope.geometryPolicy == PersistentTrajectoryCache.geometryPresentationVersion,
                  envelope.displaySafetyRevision == safetyRevision else {
                return Lookup(matches: [:], reusableRecords: [:],
                              missingPhotoIDs: Set(photos.map(\.localIdentifier)))
            }
            let stored = Dictionary(uniqueKeysWithValues: envelope.records.map { ($0.photoID, $0) })
            var matches: [String: TrailSnapResult] = [:]
            var reusable: [String: PhotoTrajectoryAssociationRecord] = [:]
            var missing = Set<String>()
            for photo in photos {
                guard let record = stored[photo.localIdentifier],
                      record.photoFingerprint == PhotoTrajectoryAssociationRecord.fingerprint(photo),
                      let result = record.result else {
                    missing.insert(photo.localIdentifier)
                    continue
                }
                matches[photo.localIdentifier] = result
                reusable[photo.localIdentifier] = record
            }
            return Lookup(matches: matches, reusableRecords: reusable, missingPhotoIDs: missing)
        }
    }

    @discardableResult
    func save(records: [String: PhotoTrajectoryAssociationRecord], safetyRevision: Int) -> Bool {
        let envelope = Envelope(schema: 1,
            geometryPolicy: PersistentTrajectoryCache.geometryPresentationVersion,
            displaySafetyRevision: safetyRevision,
            records: records.values.sorted { $0.photoID < $1.photoID })
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(envelope), data.count <= Self.maximumBytes else { return false }
        return lock.withLock {
            guard DataRevisionStore.displaySafetyRevision() == safetyRevision else { return false }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                var persistedURL = url; try? persistedURL.setResourceValues(values)
                return true
            } catch { return false }
        }
    }

    func clear() { lock.withLock { try? FileManager.default.removeItem(at: url) } }
}
