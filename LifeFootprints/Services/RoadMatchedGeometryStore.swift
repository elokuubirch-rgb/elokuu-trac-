import Foundation

/// 可删除、可重建的贴路显示缓存。数据修订或算法版本不一致时整份失效。
final class RoadMatchedGeometryStore: @unchecked Sendable {
    static let shared = RoadMatchedGeometryStore(fileURL: defaultURL())
    static let schemaVersion = 2

    private struct Envelope: Codable {
        let schemaVersion: Int
        let dataRevision: Int
        let algorithmVersion: Int
        let createdAt: Date
        let segments: [String: RoadMatchedSegment]
    }

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load(dataRevision: Int) -> [String: RoadMatchedSegment]? {
        lock.withLock {
            guard let data = try? Data(contentsOf: fileURL),
                  let envelope = try? PropertyListDecoder().decode(
                    Envelope.self, from: data),
                  envelope.schemaVersion == Self.schemaVersion,
                  envelope.dataRevision == dataRevision,
                  envelope.algorithmVersion == RoadMatchValidator.algorithmVersion else {
                return nil
            }
            return envelope.segments.filter { $0.value.usesRoadGeometry }
        }
    }

    @discardableResult
    func save(_ segments: [String: RoadMatchedSegment], dataRevision: Int) -> Bool {
        lock.withLock {
            let valid = segments.filter { $0.value.usesRoadGeometry }
            let envelope = Envelope(
                schemaVersion: Self.schemaVersion,
                dataRevision: dataRevision,
                algorithmVersion: RoadMatchValidator.algorithmVersion,
                createdAt: Date(), segments: valid)
            do {
                let data = try PropertyListEncoder().encode(envelope)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                return true
            } catch {
                return false
            }
        }
    }

    func clear() {
        lock.withLock { try? FileManager.default.removeItem(at: fileURL) }
    }

    private static func defaultURL() -> URL {
        let base = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(
            "road-matched-geometry-v2.plist", isDirectory: false)
    }
}
