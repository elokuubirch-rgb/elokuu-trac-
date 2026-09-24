import Foundation
import Compression

struct TrajectoryCacheConfiguration: Equatable, Sendable {
    static let standard = TrajectoryCacheConfiguration(
        softDiskBudget: 96 * 1_024 * 1_024,
        hardDiskBudget: 128 * 1_024 * 1_024,
        schemaVersion: 3,
        chunkSize: 8 * 1_024 * 1_024,
        lodLevels: 5)

    let softDiskBudget: Int64
    let hardDiskBudget: Int64
    let schemaVersion: Int
    let chunkSize: Int
    let lodLevels: Int

    init(softDiskBudget: Int64, hardDiskBudget: Int64,
         schemaVersion: Int, chunkSize: Int, lodLevels: Int) {
        precondition(softDiskBudget > 0 && hardDiskBudget >= softDiskBudget)
        precondition(chunkSize > 0 && lodLevels > 0)
        self.softDiskBudget = softDiskBudget
        self.hardDiskBudget = hardDiskBudget
        self.schemaVersion = schemaVersion
        self.chunkSize = chunkSize
        self.lodLevels = lodLevels
    }
}

enum TrajectoryCacheBudgetState: String, Equatable, Sendable {
    case normal
    case aboveSoftBudget
    case aboveHardBudget
}

struct TrajectoryCacheDiskSnapshot: Equatable, Sendable {
    let bytes: Int64
    let budgetState: TrajectoryCacheBudgetState
}

/// A previous v3 generation can seed an additive refresh without materializing
/// its million-scale resolved-point projection. Raw SwiftData remains authoritative.
struct StaleTrajectoryCacheSnapshot: Sendable {
    let trajectories: [Trajectory]
    let dataRevision: Int
    let createdAt: Date
}

struct TrajectoryCacheMetrics: Equatable, Sendable {
    let trajectoryCount: Int
    let segmentCount: Int
    let canonicalPointCount: Int
    let resolvedPointCount: Int
    let conflictCount: Int
    let lodPointCount: Int
    let totalBytes: Int
    let metadataBytes: Int
    let geometryBytes: Int
    let indexBytes: Int
    let conflictBytes: Int
    let resolvedMetadataBytes: Int

    var bytesPerCanonicalPoint: Double {
        canonicalPointCount > 0 ? Double(totalBytes) / Double(canonicalPointCount) : 0
    }
}

/// 可删除、可重建的派生缓存。Raw SwiftData 永远是唯一事实来源。
///
/// v3 使用按轨迹内容寻址的压缩块和原子 manifest；逐点解析 metadata 由规则恢复，
/// 只持久化冲突区间和特殊值。v1/v2 仍可读取，成功后尝试升级派生缓存。
final class PersistentTrajectoryCache: @unchecked Sendable {
    static let shared = PersistentTrajectoryCache(
        fileURL: defaultURL(), legacyFileURL: legacyURL())
    static let schemaVersion = 2
    static let chunkedSchemaVersion = 3
    static let legacySchemaVersion = 1
    static let geometryPresentationVersion = 3

    private let fileURL: URL
    private let legacyFileURL: URL?
    private let chunkedDirectoryURL: URL
    private var chunkedManifestURL: URL {
        chunkedDirectoryURL.appendingPathComponent("manifest-v3.plist")
    }
    let configuration: TrajectoryCacheConfiguration
    private let lock = NSLock()
    private var latestMetrics: TrajectoryCacheMetrics?

    init(fileURL: URL, legacyFileURL: URL? = nil,
         configuration: TrajectoryCacheConfiguration = .standard) {
        self.fileURL = fileURL
        self.legacyFileURL = legacyFileURL
        self.configuration = configuration
        self.chunkedDirectoryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("trajectory-resolution-v3", isDirectory: true)
    }

    func load(dataRevision: Int) -> TrajectoryResolution? {
        lock.withLock {
            autoreleasepool {
                if FileManager.default.fileExists(atPath: chunkedManifestURL.path) {
                    do {
                        return try loadChunked(dataRevision: dataRevision)
                    } catch let error as CacheDecodeError {
                        recordMiss("v3.\(error.reason)", revision: dataRevision)
                        if error == .revision || error == .geometryPresentation
                            || error == .schema {
                            return nil
                        }
                    } catch {
                        recordMiss("v3.corrupt", revision: dataRevision)
                    }
                }
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    do {
                        let resolution = try loadBinary(dataRevision: dataRevision)
                        // 首次命中旧 v2 后原地升级。manifest 成功落盘后才删除旧文件，
                        // 中断时仍可继续使用旧缓存。
                        _ = try? writeChunkedLocked(
                            resolution, dataRevision: dataRevision)
                        return resolution
                    } catch let error as CacheDecodeError {
                        recordMiss(error.reason, revision: dataRevision)
                        if error == .revision || error == .geometryPresentation
                            || error == .schema {
                            return nil
                        }
                    } catch {
                        recordMiss("corrupt", revision: dataRevision)
                    }
                }

                guard let legacyFileURL,
                      FileManager.default.fileExists(atPath: legacyFileURL.path) else {
                    recordMiss("notFound", revision: dataRevision)
                    return nil
                }
                do {
                    // PropertyListDecoder 会产生大量 autoreleased Foundation 对象。
                    // 在进入 v2 编码前先排空专用 pool，避免旧 decoder graph 与
                    // 新 binary writer 的峰值重叠；返回的 resolution 仍被正常持有。
                    let resolution = try autoreleasepool {
                        try loadLegacy(from: legacyFileURL, dataRevision: dataRevision)
                    }
                    #if DEBUG
                    PerformanceDiagnostics.event(
                        "PersistentTrajectoryCache.legacyDecodePoolDrained",
                        metadata: "revision=\(dataRevision)")
                    #endif
                    // 同步写入独立 v2 文件，避免旧 revision 的后台迁移覆盖新缓存。
                    _ = try? writeChunkedLocked(resolution, dataRevision: dataRevision)
                    #if DEBUG
                    PerformanceDiagnostics.event(
                        "PersistentTrajectoryCache.migratedLegacy",
                        metadata: "revision=\(dataRevision)")
                    #endif
                    return resolution
                } catch let error as CacheDecodeError {
                    recordMiss(error.reason, revision: dataRevision)
                    return nil
                } catch {
                    recordMiss("corrupt", revision: dataRevision)
                    return nil
                }
            }
        }
    }

    /// Returns only canonical trajectories from the immediately available v3 cache.
    /// The caller must independently validate the result against current SwiftData.
    func loadStaleTrajectories(before dataRevision: Int) -> StaleTrajectoryCacheSnapshot? {
        lock.withLock {
            autoreleasepool {
                guard let data = try? Data(contentsOf: chunkedManifestURL,
                                           options: .mappedIfSafe),
                      let manifest = try? PropertyListDecoder().decode(
                        TrajectoryCacheManifest.self, from: data),
                      manifest.schemaVersion == Self.chunkedSchemaVersion,
                      manifest.geometryPresentationVersion == Self.geometryPresentationVersion,
                      manifest.dataRevision < dataRevision,
                      Set(manifest.chunks.map(\.trajectoryID)).count == manifest.chunks.count
                else { return nil }
                do {
                    let chunksDirectory = chunkedDirectoryURL.appendingPathComponent(
                        "trajectory", isDirectory: true)
                    var trajectories: [Trajectory] = []
                    trajectories.reserveCapacity(manifest.chunks.count)
                    for descriptor in manifest.chunks {
                        let decoded = try decodeChunk(
                            descriptor, chunksDirectory: chunksDirectory)
                        trajectories.append(decoded.resolution.trajectories[0])
                    }
                    #if DEBUG
                    PerformanceDiagnostics.event(
                        "PersistentTrajectoryCache.staleTrajectoryHit",
                        metadata: "cached=\(manifest.dataRevision) current=\(dataRevision) chunks=\(manifest.chunks.count)")
                    PerformanceDiagnostics.count(
                        "PersistentTrajectoryCache.staleTrajectoryHit")
                    #endif
                    return StaleTrajectoryCacheSnapshot(
                        trajectories: trajectories,
                        dataRevision: manifest.dataRevision,
                        createdAt: manifest.createdAt)
                } catch {
                    #if DEBUG
                    PerformanceDiagnostics.event(
                        "PersistentTrajectoryCache.staleTrajectoryRejected",
                        metadata: error.localizedDescription)
                    #endif
                    return nil
                }
            }
        }
    }

    @discardableResult
    func save(_ resolution: TrajectoryResolution, dataRevision: Int,
              sourceReadStartedAt: Date = Date()) -> Bool {
        lock.withLock {
            do {
                try writeChunkedLocked(resolution, dataRevision: dataRevision,
                                       sourceReadStartedAt: sourceReadStartedAt)
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

    func clear() {
        lock.withLock {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: chunkedDirectoryURL)
            if let legacyFileURL {
                try? FileManager.default.removeItem(at: legacyFileURL)
            }
            latestMetrics = nil
        }
    }

    func metricsSnapshot() -> TrajectoryCacheMetrics? {
        lock.withLock { latestMetrics }
    }

    func diskSnapshot(additionalDerivedBytes: Int64 = 0) -> TrajectoryCacheDiskSnapshot {
        lock.withLock {
            let bytes = [fileURL, legacyFileURL].compactMap { $0 }
                .reduce(Int64(0)) { $0 + Self.allocatedBytes(at: $1) }
                + Self.allocatedBytes(at: chunkedDirectoryURL)
                + max(0, additionalDerivedBytes)
            let state: TrajectoryCacheBudgetState
            if bytes > configuration.hardDiskBudget {
                state = .aboveHardBudget
            } else if bytes > configuration.softDiskBudget {
                state = .aboveSoftBudget
            } else {
                state = .normal
            }
            return TrajectoryCacheDiskSnapshot(bytes: bytes, budgetState: state)
        }
    }

    private func loadChunked(dataRevision: Int) throws -> TrajectoryResolution {
        let manifestData = try Data(contentsOf: chunkedManifestURL, options: .mappedIfSafe)
        let manifest = try PropertyListDecoder().decode(
            TrajectoryCacheManifest.self, from: manifestData)
        guard manifest.schemaVersion == Self.chunkedSchemaVersion else {
            throw CacheDecodeError.schema
        }
        guard manifest.geometryPresentationVersion == Self.geometryPresentationVersion else {
            throw CacheDecodeError.geometryPresentation
        }
        guard manifest.dataRevision == dataRevision else {
            throw CacheDecodeError.revision
        }
        guard Set(manifest.chunks.map(\.trajectoryID)).count == manifest.chunks.count else {
            throw CacheDecodeError.corrupt
        }

        var trajectories: [Trajectory] = []
        trajectories.reserveCapacity(manifest.chunks.count)
        var geometryBytes = 0
        var indexBytes = 0
        var canonicalPointCount = 0
        var segmentCount = 0
        let chunksDirectory = chunkedDirectoryURL.appendingPathComponent(
            "trajectory", isDirectory: true)
        for descriptor in manifest.chunks {
            let decoded = try decodeChunk(
                descriptor, chunksDirectory: chunksDirectory)
            trajectories.append(decoded.resolution.trajectories[0])
            geometryBytes += decoded.metrics.geometryBytes
            indexBytes += decoded.metrics.indexBytes
            canonicalPointCount += decoded.canonicalPointCount
            segmentCount += decoded.metrics.segmentCount
        }
        let baseResolution = TrajectoryConflictResolver.materialize(
            trajectories, conflicts: manifest.conflicts,
            comparedPairCount: manifest.comparedPairCount)
        let resolution = Self.applying(
            manifest.pointExceptions, to: baseResolution)
        let totalBytes = Int(Self.allocatedBytes(at: chunkedDirectoryURL))
        let conflictBytes = min(totalBytes, manifest.conflictEncodedBytes)
        let componentBytes = min(totalBytes, geometryBytes + indexBytes + conflictBytes)
        let metrics = TrajectoryCacheMetrics(
            trajectoryCount: trajectories.count,
            segmentCount: segmentCount,
            canonicalPointCount: canonicalPointCount,
            resolvedPointCount: resolution.points.count,
            conflictCount: manifest.conflicts.count,
            lodPointCount: manifest.lodPointCount,
            totalBytes: totalBytes,
            metadataBytes: totalBytes - componentBytes,
            geometryBytes: min(geometryBytes, componentBytes),
            indexBytes: min(indexBytes, max(0, componentBytes - geometryBytes)),
            conflictBytes: min(conflictBytes,
                               max(0, componentBytes - geometryBytes - indexBytes)),
            resolvedMetadataBytes: 0)
        latestMetrics = metrics
        #if DEBUG
        PerformanceDiagnostics.event(
            "PersistentTrajectoryCache.hit",
            metadata: "format=v3 revision=\(dataRevision) chunks=\(manifest.chunks.count) bytes=\(totalBytes)")
        PerformanceDiagnostics.count("PersistentTrajectoryCache.hit")
        recordMetrics(metrics, operation: "load", revision: dataRevision)
        PerformanceDiagnostics.flush()
        #endif
        return resolution
    }

    private func decodeChunk(
        _ descriptor: TrajectoryCacheChunkDescriptor,
        chunksDirectory: URL
    ) throws -> FlatBinaryCodec.Decoded {
        guard descriptor.fileName == URL(fileURLWithPath: descriptor.fileName).lastPathComponent,
              descriptor.fileName.hasPrefix("chunk-"),
              descriptor.decodedSize > 0,
              descriptor.decodedSize <= 512 * 1_024 * 1_024 else {
            throw CacheDecodeError.corrupt
        }
        let url = chunksDirectory.appendingPathComponent(descriptor.fileName)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == descriptor.encodedSize,
              StableCacheFingerprint.hex(of: data) == descriptor.checksum else {
            throw CacheDecodeError.corrupt
        }
        let decodedData: Data
        switch descriptor.compression {
        case "none": decodedData = data
        case "lzfse":
            guard let value = CacheCompression.decompressLZFSE(
                data, expectedSize: descriptor.decodedSize) else {
                throw CacheDecodeError.corrupt
            }
            decodedData = value
        default: throw CacheDecodeError.corrupt
        }
        let decoded = try FlatBinaryCodec.decode(
            decodedData, expectedRevision: descriptor.localRevision,
            expectedGeometryVersion: Self.geometryPresentationVersion)
        guard decoded.resolution.trajectories.count == 1,
              decoded.resolution.trajectories[0].id == descriptor.trajectoryID,
              decoded.resolution.points.isEmpty,
              decoded.resolution.conflicts.isEmpty else {
            throw CacheDecodeError.corrupt
        }
        return decoded
    }

    private func writeChunkedLocked(_ resolution: TrajectoryResolution,
                                    dataRevision: Int,
                                    sourceReadStartedAt: Date = Date()) throws {
        let fileManager = FileManager.default
        let chunksDirectory = chunkedDirectoryURL.appendingPathComponent(
            "trajectory", isDirectory: true)
        try fileManager.createDirectory(
            at: chunksDirectory, withIntermediateDirectories: true)

        let previousManifest: TrajectoryCacheManifest? = {
            guard let data = try? Data(contentsOf: chunkedManifestURL) else { return nil }
            return try? PropertyListDecoder().decode(
                TrajectoryCacheManifest.self, from: data)
        }()
        var previousByTrajectory: [String: TrajectoryCacheChunkDescriptor] = [:]
        if previousManifest?.schemaVersion == Self.chunkedSchemaVersion,
           previousManifest?.geometryPresentationVersion == Self.geometryPresentationVersion {
            for descriptor in previousManifest?.chunks ?? [] {
                previousByTrajectory[descriptor.trajectoryID] = descriptor
            }
        }
        guard Set(resolution.trajectories.map(\.id)).count == resolution.trajectories.count else {
            throw CacheDecodeError.corrupt
        }
        let pointExceptions = try Self.pointExceptions(in: resolution)

        var descriptors: [TrajectoryCacheChunkDescriptor] = []
        descriptors.reserveCapacity(resolution.trajectories.count)
        var rewritten = 0
        var reused = 0
        for trajectory in resolution.trajectories.sorted(by: { $0.id < $1.id }) {
            let fingerprint = StableCacheFingerprint.hex(of: trajectory)
            // 内容寻址：提交新 manifest 前，不覆盖旧 manifest 引用的块。
            let fileName = "chunk-\(StableCacheFingerprint.hex(of: trajectory.id))-\(fingerprint).bin"
            let url = chunksDirectory.appendingPathComponent(fileName)
            if let previous = previousByTrajectory[trajectory.id],
               previous.fingerprint == fingerprint,
               previous.fileName == fileName,
               let existing = try? Data(contentsOf: url, options: .mappedIfSafe),
               existing.count == previous.encodedSize,
               StableCacheFingerprint.hex(of: existing) == previous.checksum {
                descriptors.append(previous)
                reused += 1
                continue
            }

            let localRevision = StableCacheFingerprint.localRevision(fingerprint)
            let chunkResolution = TrajectoryResolution(
                trajectories: [trajectory], conflicts: [], points: [],
                comparedPairCount: 0)
            let encoded = try FlatBinaryCodec.encode(
                chunkResolution, dataRevision: localRevision,
                geometryVersion: Self.geometryPresentationVersion)
            let storedData: Data
            let compression: String
            if let compressed = CacheCompression.compressLZFSE(encoded.data),
               compressed.count < encoded.data.count {
                storedData = compressed
                compression = "lzfse"
            } else {
                storedData = encoded.data
                compression = "none"
            }
            try storedData.write(to: url, options: .atomic)
            let bounds = TrajectoryCacheChunkDescriptor.bounds(of: trajectory)
            descriptors.append(TrajectoryCacheChunkDescriptor(
                chunkID: StableCacheFingerprint.hex(of: trajectory.id),
                fileName: fileName,
                trajectoryID: trajectory.id,
                source: trajectory.source.rawValue,
                startTime: trajectory.startTime,
                endTime: trajectory.endTime,
                minimumLatitude: bounds?.minimumLatitude,
                minimumLongitude: bounds?.minimumLongitude,
                maximumLatitude: bounds?.maximumLatitude,
                maximumLongitude: bounds?.maximumLongitude,
                pointCount: encoded.metrics.canonicalPointCount,
                segmentCount: encoded.metrics.segmentCount,
                localRevision: localRevision,
                fingerprint: fingerprint,
                encodedSize: storedData.count,
                decodedSize: encoded.data.count,
                compression: compression,
                checksum: StableCacheFingerprint.hex(of: storedData),
                metadataBytes: encoded.metrics.metadataBytes,
                geometryBytes: encoded.metrics.geometryBytes,
                indexBytes: encoded.metrics.indexBytes))
            rewritten += 1
        }

        let sparsePayload = TrajectoryCacheSparsePayload(
            conflicts: resolution.conflicts, pointExceptions: pointExceptions)
        let conflictEncodedBytes = (try? PropertyListEncoder().encode(
            sparsePayload).count) ?? 0
        let manifest = TrajectoryCacheManifest(
            schemaVersion: Self.chunkedSchemaVersion,
            geometryPresentationVersion: Self.geometryPresentationVersion,
            dataRevision: dataRevision,
            // This is the lower bound of source observation, not serialization end.
            // Routes written during a slow read must still be refreshed next time.
            createdAt: sourceReadStartedAt,
            comparedPairCount: resolution.comparedPairCount,
            conflictEncodedBytes: conflictEncodedBytes,
            lodPointCount: 0,
            chunks: descriptors,
            conflicts: resolution.conflicts,
            pointExceptions: pointExceptions)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: chunkedManifestURL, options: .atomic)

        // manifest 已经成为新的一致性边界，此后才清理未引用 chunk 和旧格式。
        let retainedNames = Set(descriptors.map(\.fileName))
        if let urls = try? fileManager.contentsOfDirectory(
            at: chunksDirectory, includingPropertiesForKeys: nil) {
            for url in urls where url.lastPathComponent.hasPrefix("chunk-")
                && url.pathExtension == "bin" && !retainedNames.contains(url.lastPathComponent) {
                try? fileManager.removeItem(at: url)
            }
        }
        try? fileManager.removeItem(at: fileURL)
        if let legacyFileURL { try? fileManager.removeItem(at: legacyFileURL) }

        let totalBytes = Int(Self.allocatedBytes(at: chunkedDirectoryURL))
        let geometryBytes = descriptors.reduce(0) { $0 + $1.geometryBytes }
        let indexBytes = descriptors.reduce(0) { $0 + $1.indexBytes }
        let safeConflictBytes = min(totalBytes, conflictEncodedBytes)
        let componentBytes = min(totalBytes, geometryBytes + indexBytes + safeConflictBytes)
        let metrics = TrajectoryCacheMetrics(
            trajectoryCount: descriptors.count,
            segmentCount: descriptors.reduce(0) { $0 + $1.segmentCount },
            canonicalPointCount: descriptors.reduce(0) { $0 + $1.pointCount },
            resolvedPointCount: resolution.points.count,
            conflictCount: resolution.conflicts.count,
            lodPointCount: 0,
            totalBytes: totalBytes,
            metadataBytes: totalBytes - componentBytes,
            geometryBytes: min(geometryBytes, componentBytes),
            indexBytes: min(indexBytes, max(0, componentBytes - geometryBytes)),
            conflictBytes: min(safeConflictBytes,
                               max(0, componentBytes - geometryBytes - indexBytes)),
            resolvedMetadataBytes: 0)
        latestMetrics = metrics
        #if DEBUG
        PerformanceDiagnostics.event(
            "PersistentTrajectoryCache.saved",
            metadata: "format=v3 revision=\(dataRevision) chunks=\(descriptors.count) reused=\(reused) rewritten=\(rewritten) bytes=\(totalBytes)")
        PerformanceDiagnostics.count("PersistentTrajectoryCache.saved")
        PerformanceDiagnostics.count("TrajectoryCache.chunks.reused", by: reused)
        PerformanceDiagnostics.count("TrajectoryCache.chunks.rewritten", by: rewritten)
        recordMetrics(metrics, operation: "save", revision: dataRevision)
        #endif

        if Int64(totalBytes) > configuration.hardDiskBudget {
            appLog.warning("[TrajectoryCache] v3 稀疏分块缓存仍超过硬预算：\(totalBytes) > \(self.configuration.hardDiskBudget)")
        } else if Int64(totalBytes) > configuration.softDiskBudget {
            appLog.info("[TrajectoryCache] v3 分块缓存超过软预算：\(totalBytes) > \(self.configuration.softDiskBudget)")
        }
    }

    private static func allocatedBytes(at url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        else { return 0 }
        if !isDirectory.boolValue {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return 0 }
        var result: Int64 = 0
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                result += Int64(values?.fileSize ?? 0)
            }
        }
        return result
    }

    private static func pointExceptions(
        in resolution: TrajectoryResolution
    ) throws -> [TrajectoryPointResolutionException] {
        // 所有规模都保留异常。按解析器的稳定顺序逐点比较，避免额外的逐点字符串字典。
        let baseline = TrajectoryConflictResolver.materialize(
            resolution.trajectories, conflicts: resolution.conflicts,
            comparedPairCount: resolution.comparedPairCount)
        guard baseline.points.count == resolution.points.count else {
            throw CacheDecodeError.corrupt
        }
        return try zip(resolution.points, baseline.points).compactMap { point, expected in
            guard point.trajectoryID == expected.trajectoryID, point.point == expected.point else {
                throw CacheDecodeError.corrupt
            }
            guard expected.sessionID != point.sessionID
                    || expected.segmentID != point.segmentID
                    || expected.source != point.source
                    || expected.confidence != point.confidence
                    || expected.suppressedByTrajectoryID != point.suppressedByTrajectoryID
                    || expected.suppressedBySource != point.suppressedBySource else {
                return nil
            }
            return TrajectoryPointResolutionException(
                trajectoryID: point.trajectoryID, pointID: point.point.id,
                sessionID: point.sessionID, segmentID: point.segmentID,
                source: point.source.rawValue, confidence: point.confidence,
                suppressedByTrajectoryID: point.suppressedByTrajectoryID,
                suppressedBySource: point.suppressedBySource?.rawValue)
        }
    }

    private static func applying(
        _ exceptions: [TrajectoryPointResolutionException],
        to resolution: TrajectoryResolution
    ) -> TrajectoryResolution {
        guard !exceptions.isEmpty else { return resolution }
        var byKey: [String: TrajectoryPointResolutionException] = [:]
        byKey.reserveCapacity(exceptions.count)
        for exception in exceptions {
            byKey["\(exception.trajectoryID)\u{0}\(exception.pointID)"] = exception
        }
        let points = resolution.points.map { point -> ResolvedTrajectoryPoint in
            let key = "\(point.trajectoryID)\u{0}\(point.point.id)"
            guard let exception = byKey[key],
                  let source = TrajectorySource(rawValue: exception.source) else {
                return point
            }
            return ResolvedTrajectoryPoint(
                trajectoryID: point.trajectoryID,
                sessionID: exception.sessionID,
                segmentID: exception.segmentID,
                source: source,
                point: point.point,
                confidence: exception.confidence,
                suppressedByTrajectoryID: exception.suppressedByTrajectoryID,
                suppressedBySource: exception.suppressedBySource.flatMap {
                    TrajectorySource(rawValue: $0)
                })
        }
        return TrajectoryResolution(
            trajectories: resolution.trajectories,
            conflicts: resolution.conflicts,
            points: points,
            comparedPairCount: resolution.comparedPairCount)
    }

    private func loadBinary(dataRevision: Int) throws -> TrajectoryResolution {
        #if DEBUG
        let data = try PerformanceDiagnostics.measure(
            "PersistentTrajectoryCache.read",
            metadata: "revision=\(dataRevision)") {
                try Data(contentsOf: fileURL, options: .mappedIfSafe)
            }
        let decoded = try PerformanceDiagnostics.measure(
            "PersistentTrajectoryCache.decode",
            metadata: "format=v2 bytes=\(data.count)") {
                try FlatBinaryCodec.decode(
                    data, expectedRevision: dataRevision,
                    expectedGeometryVersion: Self.geometryPresentationVersion)
            }
        recordDecoded(decoded, bytes: data.count, revision: dataRevision)
        #else
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let decoded = try FlatBinaryCodec.decode(
            data, expectedRevision: dataRevision,
            expectedGeometryVersion: Self.geometryPresentationVersion)
        #endif
        latestMetrics = decoded.metrics
        return decoded.resolution
    }

    private func loadLegacy(from url: URL,
                            dataRevision: Int) throws -> TrajectoryResolution {
        #if DEBUG
        let data = try PerformanceDiagnostics.measure(
            "PersistentTrajectoryCache.legacyRead",
            metadata: "revision=\(dataRevision)") {
                try Data(contentsOf: url, options: .mappedIfSafe)
            }
        let envelope = try PerformanceDiagnostics.measure(
            "PersistentTrajectoryCache.legacyDecode",
            metadata: "bytes=\(data.count)") {
                try PropertyListDecoder().decode(LegacyEnvelope.self, from: data)
            }
        #else
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let envelope = try PropertyListDecoder().decode(LegacyEnvelope.self, from: data)
        #endif
        guard envelope.schemaVersion == Self.legacySchemaVersion else {
            throw CacheDecodeError.schema
        }
        guard envelope.geometryPresentationVersion == Self.geometryPresentationVersion else {
            throw CacheDecodeError.geometryPresentation
        }
        guard envelope.dataRevision == dataRevision else {
            throw CacheDecodeError.revision
        }
        #if DEBUG
        let materialized = PerformanceDiagnostics.measure(
            "PersistentTrajectoryCache.legacyMaterialize",
            metadata: "points=\(envelope.canonicalPoints.count)") {
                envelope.materialize()
            }
        #else
        let materialized = envelope.materialize()
        #endif
        guard let resolution = materialized else { throw CacheDecodeError.corrupt }
        let legacySegmentCount = resolution.trajectories.reduce(0) {
            $0 + $1.segments.count
        }
        let legacyMetrics = TrajectoryCacheMetrics(
            trajectoryCount: resolution.trajectories.count,
            segmentCount: legacySegmentCount,
            canonicalPointCount: envelope.canonicalPoints.count,
            resolvedPointCount: resolution.points.count,
            conflictCount: resolution.conflicts.count,
            lodPointCount: 0,
            totalBytes: data.count,
            metadataBytes: data.count,
            geometryBytes: 0,
            indexBytes: 0,
            conflictBytes: 0,
            resolvedMetadataBytes: 0)
        latestMetrics = legacyMetrics
        #if DEBUG
        recordDecoded(
            .init(resolution: resolution,
                  canonicalPointCount: envelope.canonicalPoints.count,
                  metrics: legacyMetrics),
            bytes: data.count, revision: dataRevision)
        #endif
        return resolution
    }

    private func writeBinaryLocked(_ resolution: TrajectoryResolution,
                                   dataRevision: Int) throws {
        #if DEBUG
        let encoded = try PerformanceDiagnostics.measure(
            "PersistentTrajectoryCache.encode",
            metadata: "format=v2 points=\(resolution.points.count)") {
                try FlatBinaryCodec.encode(
                    resolution, dataRevision: dataRevision,
                    geometryVersion: Self.geometryPresentationVersion)
            }
        #else
        let encoded = try FlatBinaryCodec.encode(
            resolution, dataRevision: dataRevision,
            geometryVersion: Self.geometryPresentationVersion)
        #endif
        let data = encoded.data
        latestMetrics = encoded.metrics
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
            metadata: "format=v2 revision=\(dataRevision) bytes=\(data.count)")
        PerformanceDiagnostics.count("PersistentTrajectoryCache.saved")
        recordMetrics(encoded.metrics, operation: "save", revision: dataRevision)
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif

        if Int64(data.count) > configuration.hardDiskBudget {
            appLog.warning("[TrajectoryCache] 超过硬预算：\(data.count) > \(self.configuration.hardDiskBudget)；保留缓存等待 v3 分块压缩")
        } else if Int64(data.count) > configuration.softDiskBudget {
            appLog.info("[TrajectoryCache] 超过软预算：\(data.count) > \(self.configuration.softDiskBudget)")
        }
    }

    #if DEBUG
    private func recordDecoded(_ decoded: FlatBinaryCodec.Decoded,
                               bytes: Int, revision: Int) {
        PerformanceDiagnostics.count(
            "PersistentTrajectoryCache.decodedCanonicalPoints",
            by: decoded.canonicalPointCount)
        PerformanceDiagnostics.count(
            "PersistentTrajectoryCache.decodedTrajectories",
            by: decoded.resolution.trajectories.count)
        PerformanceDiagnostics.count(
            "PersistentTrajectoryCache.decodedResolvedPoints",
            by: decoded.resolution.points.count)
        PerformanceDiagnostics.event(
            "PersistentTrajectoryCache.hit",
            metadata: "revision=\(revision) bytes=\(bytes)")
        PerformanceDiagnostics.count("PersistentTrajectoryCache.hit")
        recordMetrics(decoded.metrics, operation: "load", revision: revision)
        PerformanceDiagnostics.flush()
    }

    private func recordMetrics(_ metrics: TrajectoryCacheMetrics,
                               operation: String, revision: Int) {
        let bytesPerPoint = String(format: "%.2f", metrics.bytesPerCanonicalPoint)
        PerformanceDiagnostics.count("TrajectoryCache.trajectories", by: metrics.trajectoryCount)
        PerformanceDiagnostics.count("TrajectoryCache.segments", by: metrics.segmentCount)
        PerformanceDiagnostics.count("TrajectoryCache.canonicalPoints", by: metrics.canonicalPointCount)
        PerformanceDiagnostics.count("TrajectoryCache.resolvedPoints", by: metrics.resolvedPointCount)
        PerformanceDiagnostics.count("TrajectoryCache.lodPoints", by: metrics.lodPointCount)
        PerformanceDiagnostics.count("TrajectoryCache.conflicts", by: metrics.conflictCount)
        PerformanceDiagnostics.event(
            "TrajectoryCache.metrics",
            metadata: "operation=\(operation) revision=\(revision) total=\(metrics.totalBytes) metadata=\(metrics.metadataBytes) geometry=\(metrics.geometryBytes) index=\(metrics.indexBytes) conflict=\(metrics.conflictBytes) resolved=\(metrics.resolvedMetadataBytes) bytesPerCanonical=\(bytesPerPoint)")
    }
    #endif

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
            .appendingPathComponent("trajectory-resolution-v2.bin")
    }

    private static func legacyURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LifeFootprintsDerived", isDirectory: true)
            .appendingPathComponent("trajectory-resolution-v1.plist")
    }
}

private struct TrajectoryCacheManifest: Codable {
    let schemaVersion: Int
    let geometryPresentationVersion: Int
    let dataRevision: Int
    let createdAt: Date
    let comparedPairCount: Int
    let conflictEncodedBytes: Int
    let lodPointCount: Int
    let chunks: [TrajectoryCacheChunkDescriptor]
    let conflicts: [TrajectoryConflict]
    let pointExceptions: [TrajectoryPointResolutionException]
}

private struct TrajectoryCacheSparsePayload: Codable {
    let conflicts: [TrajectoryConflict]
    let pointExceptions: [TrajectoryPointResolutionException]
}

private struct TrajectoryPointResolutionException: Codable {
    let trajectoryID: String
    let pointID: String
    let sessionID: String
    let segmentID: String
    let source: String
    let confidence: Double
    let suppressedByTrajectoryID: String?
    let suppressedBySource: String?
}

private struct TrajectoryCacheChunkDescriptor: Codable {
    struct Bounds {
        let minimumLatitude: Double
        let minimumLongitude: Double
        let maximumLatitude: Double
        let maximumLongitude: Double
    }

    let chunkID: String
    let fileName: String
    let trajectoryID: String
    let source: String
    let startTime: Date
    let endTime: Date
    let minimumLatitude: Double?
    let minimumLongitude: Double?
    let maximumLatitude: Double?
    let maximumLongitude: Double?
    let pointCount: Int
    let segmentCount: Int
    let localRevision: Int
    let fingerprint: String
    let encodedSize: Int
    let decodedSize: Int
    let compression: String
    let checksum: String
    let metadataBytes: Int
    let geometryBytes: Int
    let indexBytes: Int

    static func bounds(of trajectory: Trajectory) -> Bounds? {
        var minimumLatitude = Double.infinity
        var minimumLongitude = Double.infinity
        var maximumLatitude = -Double.infinity
        var maximumLongitude = -Double.infinity
        var foundPoint = false
        for segment in trajectory.segments {
            for point in segment.points {
                foundPoint = true
                minimumLatitude = min(minimumLatitude, point.latitude)
                minimumLongitude = min(minimumLongitude, point.longitude)
                maximumLatitude = max(maximumLatitude, point.latitude)
                maximumLongitude = max(maximumLongitude, point.longitude)
            }
        }
        guard foundPoint else { return nil }
        return Bounds(
            minimumLatitude: minimumLatitude,
            minimumLongitude: minimumLongitude,
            maximumLatitude: maximumLatitude,
            maximumLongitude: maximumLongitude)
    }
}

private enum StableCacheFingerprint {
    private struct Hasher {
        private(set) var value: UInt64 = 14_695_981_039_346_656_037

        mutating func combine(_ byte: UInt8) {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }

        mutating func combine(_ value: UInt64) {
            var littleEndian = value.littleEndian
            Swift.withUnsafeBytes(of: &littleEndian) { bytes in
                for byte in bytes { combine(byte) }
            }
        }

        mutating func combine(_ value: Int) { combine(UInt64(bitPattern: Int64(value))) }
        mutating func combine(_ value: Double) { combine(value.bitPattern) }
        mutating func combine(_ value: Date) { combine(value.timeIntervalSince1970) }

        mutating func combine(_ value: String?) {
            guard let value else {
                combine(UInt8.max)
                return
            }
            combine(value.utf8.count)
            for byte in value.utf8 { combine(byte) }
        }

        mutating func combine(_ value: Double?) {
            guard let value else {
                combine(UInt8.max)
                return
            }
            combine(value)
        }
    }

    static func hex(of value: String) -> String {
        var hasher = Hasher()
        hasher.combine(value)
        return String(format: "%016llx", hasher.value)
    }

    static func hex(of data: Data) -> String {
        var hasher = Hasher()
        for byte in data { hasher.combine(byte) }
        return String(format: "%016llx", hasher.value)
    }

    static func hex(of trajectory: Trajectory) -> String {
        var hasher = Hasher()
        hasher.combine(trajectory.id)
        hasher.combine(trajectory.source.rawValue)
        hasher.combine(trajectory.sourceIdentifier)
        hasher.combine(trajectory.sessionID)
        hasher.combine(trajectory.startTime)
        hasher.combine(trajectory.endTime)
        hasher.combine(trajectory.activityType)
        combine(trajectory.quality, into: &hasher)
        hasher.combine(trajectory.confidence)
        hasher.combine(trajectory.displayPriority)
        hasher.combine(trajectory.segments.count)
        for segment in trajectory.segments {
            hasher.combine(segment.id)
            hasher.combine(segment.trajectoryID)
            hasher.combine(segment.sessionID)
            hasher.combine(segment.source.rawValue)
            hasher.combine(segment.startTime)
            hasher.combine(segment.endTime)
            combine(segment.quality, into: &hasher)
            hasher.combine(segment.points.count)
            for point in segment.points {
                hasher.combine(point.id)
                hasher.combine(point.latitude)
                hasher.combine(point.longitude)
                hasher.combine(point.timestamp)
                hasher.combine(point.altitude)
                hasher.combine(point.horizontalAccuracy)
                hasher.combine(point.speed)
                hasher.combine(point.course)
                hasher.combine(point.source.rawValue)
            }
        }
        return String(format: "%016llx", hasher.value)
    }

    static func localRevision(_ fingerprint: String) -> Int {
        let value = UInt64(fingerprint, radix: 16) ?? 0
        return Int(value & UInt64(Int.max))
    }

    private static func combine(_ quality: TrajectoryQuality,
                                into hasher: inout Hasher) {
        hasher.combine(quality.pointCount)
        hasher.combine(quality.duration)
        hasher.combine(quality.maximumGap)
        hasher.combine(quality.accuratePointRatio)
        hasher.combine(quality.confidence)
    }
}

private enum CacheCompression {
    static func compressLZFSE(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let capacity = data.count
        let sourceSize = data.count
        var destination = Data(count: capacity)
        let encodedSize = data.withUnsafeBytes { sourceBuffer in
            destination.withUnsafeMutableBytes { destinationBuffer in
                guard let source = sourceBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let output = destinationBuffer.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_encode_buffer(
                    output, capacity, source, sourceSize,
                    nil, COMPRESSION_LZFSE)
            }
        }
        guard encodedSize > 0, encodedSize < data.count else { return nil }
        destination.count = encodedSize
        return destination
    }

    static func decompressLZFSE(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize >= 0 else { return nil }
        if expectedSize == 0 { return data.isEmpty ? Data() : nil }
        let sourceSize = data.count
        var destination = Data(count: expectedSize)
        let decodedSize = data.withUnsafeBytes { sourceBuffer in
            destination.withUnsafeMutableBytes { destinationBuffer in
                guard let source = sourceBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let output = destinationBuffer.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    output, expectedSize, source, sourceSize,
                    nil, COMPRESSION_LZFSE)
            }
        }
        return decodedSize == expectedSize ? destination : nil
    }
}

private enum CacheDecodeError: Error, Equatable {
    case magic, schema, geometryPresentation, revision, corrupt

    var reason: String {
        switch self {
        case .magic: return "magic"
        case .schema: return "schema"
        case .geometryPresentation: return "geometryPresentation"
        case .revision: return "revision"
        case .corrupt: return "corrupt"
        }
    }
}

// MARK: - Flat v2 binary codec

private enum FlatBinaryCodec {
    static let magic: [UInt8] = [0x4C, 0x46, 0x54, 0x52, 0x4A, 0x32, 0x00, 0x00]
    private static let maximumPointCount = 20_000_000
    private static let maximumTrajectoryCount = 1_000_000
    private static let maximumSegmentCount = 2_000_000
    private static let maximumConflictCount = 10_000_000
    private static let maximumStringCount = 5_000_000

    struct Decoded {
        let resolution: TrajectoryResolution
        let canonicalPointCount: Int
        let metrics: TrajectoryCacheMetrics
    }

    struct Encoded {
        let data: Data
        let metrics: TrajectoryCacheMetrics
    }

    static func encode(_ resolution: TrajectoryResolution,
                       dataRevision: Int,
                       geometryVersion: Int) throws -> Encoded {
        var pointIndexByID: [String: UInt32] = [:]
        pointIndexByID.reserveCapacity(resolution.points.count)

        func register(_ point: TrajectoryPoint) throws {
            if pointIndexByID[point.id] != nil { return }
            guard pointIndexByID.count < Int(UInt32.max) else {
                throw CacheDecodeError.corrupt
            }
            let index = UInt32(pointIndexByID.count)
            pointIndexByID[point.id] = index
        }

        for trajectory in resolution.trajectories {
            for segment in trajectory.segments {
                for point in segment.points { try register(point) }
            }
        }
        for resolved in resolution.points { try register(resolved.point) }

        var strings = StringTable()
        for trajectory in resolution.trajectories {
            strings.register(trajectory.id)
            strings.register(trajectory.sourceIdentifier)
            strings.register(trajectory.sessionID)
            strings.register(trajectory.activityType)
            for segment in trajectory.segments {
                strings.register(segment.id)
                strings.register(segment.trajectoryID)
                strings.register(segment.sessionID)
            }
        }
        for conflict in resolution.conflicts {
            strings.register(conflict.winnerTrajectoryID)
            strings.register(conflict.suppressedTrajectoryID)
        }
        for resolved in resolution.points {
            strings.register(resolved.trajectoryID)
            strings.register(resolved.sessionID)
            strings.register(resolved.segmentID)
            strings.register(resolved.suppressedByTrajectoryID)
        }

        var writer = BinaryWriter(capacity: max(1_024, pointIndexByID.count * 72))
        writer.append(bytes: magic)
        writer.append(UInt32(PersistentTrajectoryCache.schemaVersion))
        writer.append(UInt32(geometryVersion))
        writer.append(Int64(dataRevision))
        writer.append(Date().timeIntervalSince1970)
        writer.append(Int64(resolution.comparedPairCount))

        try writer.appendCount(strings.values.count)
        for value in strings.values { try writer.append(value) }
        let metadataPrefixBytes = writer.data.count

        let geometryStart = writer.data.count
        try writer.appendCount(pointIndexByID.count)
        // 与上面的注册遍历保持完全相同的顺序，直接写入首次出现的现有点。
        // 这样产生的 canonical 序列及所有下标与旧实现一致，但不再额外复制
        // 一整份 million-scale [TrajectoryPoint]。
        var emittedCanonicalCount = 0
        for trajectory in resolution.trajectories {
            for segment in trajectory.segments {
                for point in segment.points {
                    guard pointIndexByID[point.id] == UInt32(emittedCanonicalCount) else {
                        continue
                    }
                    try writer.append(point)
                    emittedCanonicalCount += 1
                }
            }
        }
        for resolved in resolution.points {
            let point = resolved.point
            guard pointIndexByID[point.id] == UInt32(emittedCanonicalCount) else {
                continue
            }
            try writer.append(point)
            emittedCanonicalCount += 1
        }
        guard emittedCanonicalCount == pointIndexByID.count else {
            throw CacheDecodeError.corrupt
        }
        let geometryBytes = writer.data.count - geometryStart

        let trajectoryStart = writer.data.count
        var pointIndexBytes = 0
        var segmentCount = 0
        try writer.appendCount(resolution.trajectories.count)
        for trajectory in resolution.trajectories {
            try writer.appendStringIndex(trajectory.id, table: strings)
            writer.append(source: trajectory.source)
            try writer.appendOptionalStringIndex(trajectory.sourceIdentifier, table: strings)
            try writer.appendStringIndex(trajectory.sessionID, table: strings)
            writer.append(trajectory.startTime.timeIntervalSince1970)
            writer.append(trajectory.endTime.timeIntervalSince1970)
            try writer.appendOptionalStringIndex(trajectory.activityType, table: strings)
            try writer.append(quality: trajectory.quality)
            writer.append(trajectory.confidence)
            writer.append(Int64(trajectory.displayPriority))
            try writer.appendCount(trajectory.segments.count)
            segmentCount += trajectory.segments.count
            for segment in trajectory.segments {
                try writer.appendStringIndex(segment.id, table: strings)
                try writer.appendStringIndex(segment.trajectoryID, table: strings)
                try writer.appendStringIndex(segment.sessionID, table: strings)
                writer.append(source: segment.source)
                writer.append(segment.startTime.timeIntervalSince1970)
                writer.append(segment.endTime.timeIntervalSince1970)
                try writer.append(quality: segment.quality)
                let indexStart = writer.data.count
                try writer.appendCount(segment.points.count)
                for point in segment.points {
                    guard let index = pointIndexByID[point.id] else {
                        throw CacheDecodeError.corrupt
                    }
                    writer.append(index)
                }
                pointIndexBytes += writer.data.count - indexStart
            }
        }
        let trajectoryBytes = writer.data.count - trajectoryStart

        let conflictStart = writer.data.count
        try writer.appendCount(resolution.conflicts.count)
        for conflict in resolution.conflicts {
            try writer.appendStringIndex(conflict.winnerTrajectoryID, table: strings)
            try writer.appendStringIndex(conflict.suppressedTrajectoryID, table: strings)
            writer.append(conflict.startTime.timeIntervalSince1970)
            writer.append(conflict.endTime.timeIntervalSince1970)
            writer.append(conflict.overlapRatio)
            writer.append(conflict.matchingPointRatio)
            writer.append(conflict.medianDistanceMeters)
        }
        let conflictBytes = writer.data.count - conflictStart

        let resolvedStart = writer.data.count
        var resolvedIndexBytes = 0
        try writer.appendCount(resolution.points.count)
        for resolved in resolution.points {
            try writer.appendStringIndex(resolved.trajectoryID, table: strings)
            try writer.appendStringIndex(resolved.sessionID, table: strings)
            try writer.appendStringIndex(resolved.segmentID, table: strings)
            writer.append(source: resolved.source)
            guard let pointIndex = pointIndexByID[resolved.point.id] else {
                throw CacheDecodeError.corrupt
            }
            let pointIndexStart = writer.data.count
            writer.append(pointIndex)
            resolvedIndexBytes += writer.data.count - pointIndexStart
            writer.append(resolved.confidence)
            try writer.appendOptionalStringIndex(
                resolved.suppressedByTrajectoryID, table: strings)
            writer.append(optionalSource: resolved.suppressedBySource)
        }
        let resolvedBytes = writer.data.count - resolvedStart
        let indexBytes = pointIndexBytes + resolvedIndexBytes
        let metrics = TrajectoryCacheMetrics(
            trajectoryCount: resolution.trajectories.count,
            segmentCount: segmentCount,
            canonicalPointCount: pointIndexByID.count,
            resolvedPointCount: resolution.points.count,
            conflictCount: resolution.conflicts.count,
            lodPointCount: 0,
            totalBytes: writer.data.count,
            metadataBytes: metadataPrefixBytes + trajectoryBytes - pointIndexBytes,
            geometryBytes: geometryBytes,
            indexBytes: indexBytes,
            conflictBytes: conflictBytes,
            resolvedMetadataBytes: resolvedBytes - resolvedIndexBytes)
        return Encoded(data: writer.data, metrics: metrics)
    }

    static func decode(_ data: Data,
                       expectedRevision: Int,
                       expectedGeometryVersion: Int) throws -> Decoded {
        var reader = BinaryReader(data: data)
        guard try reader.readBytes(count: magic.count) == magic else {
            throw CacheDecodeError.magic
        }
        guard try reader.readUInt32() == UInt32(PersistentTrajectoryCache.schemaVersion) else {
            throw CacheDecodeError.schema
        }
        guard try reader.readUInt32() == UInt32(expectedGeometryVersion) else {
            throw CacheDecodeError.geometryPresentation
        }
        guard try reader.readInt64() == Int64(expectedRevision) else {
            throw CacheDecodeError.revision
        }
        _ = try reader.readDouble()
        let comparedPairCount = try reader.readInt()

        let stringCount = try reader.readCount(maximum: maximumStringCount)
        var strings: [String] = []
        strings.reserveCapacity(stringCount)
        for _ in 0..<stringCount { strings.append(try reader.readString()) }
        let metadataPrefixBytes = reader.offset

        let geometryStart = reader.offset
        let canonicalCount = try reader.readCount(maximum: maximumPointCount)
        var canonicalPoints: [TrajectoryPoint] = []
        canonicalPoints.reserveCapacity(canonicalCount)
        for _ in 0..<canonicalCount {
            canonicalPoints.append(try reader.readTrajectoryPoint())
        }
        let geometryBytes = reader.offset - geometryStart

        let trajectoryStart = reader.offset
        let trajectoryCount = try reader.readCount(maximum: maximumTrajectoryCount)
        var trajectories: [Trajectory] = []
        trajectories.reserveCapacity(trajectoryCount)
        var totalSegmentCount = 0
        var pointIndexBytes = 0
        for _ in 0..<trajectoryCount {
            let id = try reader.readString(from: strings)
            let source = try reader.readSource()
            let sourceIdentifier = try reader.readOptionalString(from: strings)
            let sessionID = try reader.readString(from: strings)
            let startTime = Date(timeIntervalSince1970: try reader.readDouble())
            let endTime = Date(timeIntervalSince1970: try reader.readDouble())
            let activityType = try reader.readOptionalString(from: strings)
            let quality = try reader.readQuality()
            let confidence = try reader.readDouble()
            let displayPriority = try reader.readInt()
            let segmentCount = try reader.readCount(maximum: maximumSegmentCount)
            totalSegmentCount += segmentCount
            guard totalSegmentCount <= maximumSegmentCount else {
                throw CacheDecodeError.corrupt
            }
            var segments: [TrajectorySegment] = []
            segments.reserveCapacity(segmentCount)
            for _ in 0..<segmentCount {
                let segmentID = try reader.readString(from: strings)
                let trajectoryID = try reader.readString(from: strings)
                let segmentSessionID = try reader.readString(from: strings)
                let segmentSource = try reader.readSource()
                let segmentStart = Date(timeIntervalSince1970: try reader.readDouble())
                let segmentEnd = Date(timeIntervalSince1970: try reader.readDouble())
                let segmentQuality = try reader.readQuality()
                let indexStart = reader.offset
                let pointCount = try reader.readCount(maximum: maximumPointCount)
                var points: [TrajectoryPoint] = []
                points.reserveCapacity(pointCount)
                for _ in 0..<pointCount {
                    let index = try reader.readIndex(count: canonicalPoints.count)
                    points.append(canonicalPoints[index])
                }
                pointIndexBytes += reader.offset - indexStart
                segments.append(TrajectorySegment(
                    id: segmentID, trajectoryID: trajectoryID,
                    sessionID: segmentSessionID, source: segmentSource,
                    points: points, startTime: segmentStart, endTime: segmentEnd,
                    quality: segmentQuality))
            }
            trajectories.append(Trajectory(
                id: id, source: source, sourceIdentifier: sourceIdentifier,
                sessionID: sessionID, startTime: startTime, endTime: endTime,
                activityType: activityType, segments: segments, quality: quality,
                confidence: confidence, displayPriority: displayPriority))
        }
        let trajectoryBytes = reader.offset - trajectoryStart

        let conflictStart = reader.offset
        let conflictCount = try reader.readCount(maximum: maximumConflictCount)
        var conflicts: [TrajectoryConflict] = []
        conflicts.reserveCapacity(conflictCount)
        for _ in 0..<conflictCount {
            conflicts.append(TrajectoryConflict(
                winnerTrajectoryID: try reader.readString(from: strings),
                suppressedTrajectoryID: try reader.readString(from: strings),
                startTime: Date(timeIntervalSince1970: try reader.readDouble()),
                endTime: Date(timeIntervalSince1970: try reader.readDouble()),
                overlapRatio: try reader.readDouble(),
                matchingPointRatio: try reader.readDouble(),
                medianDistanceMeters: try reader.readDouble()))
        }
        let conflictBytes = reader.offset - conflictStart

        let resolvedStart = reader.offset
        var resolvedIndexBytes = 0
        let resolvedCount = try reader.readCount(maximum: maximumPointCount)
        var resolvedPoints: [ResolvedTrajectoryPoint] = []
        resolvedPoints.reserveCapacity(resolvedCount)
        for _ in 0..<resolvedCount {
            let trajectoryID = try reader.readString(from: strings)
            let sessionID = try reader.readString(from: strings)
            let segmentID = try reader.readString(from: strings)
            let source = try reader.readSource()
            let pointIndexStart = reader.offset
            let pointIndex = try reader.readIndex(count: canonicalPoints.count)
            resolvedIndexBytes += reader.offset - pointIndexStart
            let confidence = try reader.readDouble()
            let suppressedID = try reader.readOptionalString(from: strings)
            let suppressedSource = try reader.readOptionalSource()
            resolvedPoints.append(ResolvedTrajectoryPoint(
                trajectoryID: trajectoryID, sessionID: sessionID,
                segmentID: segmentID, source: source,
                point: canonicalPoints[pointIndex], confidence: confidence,
                suppressedByTrajectoryID: suppressedID,
                suppressedBySource: suppressedSource))
        }
        let resolvedBytes = reader.offset - resolvedStart
        guard reader.isAtEnd else { throw CacheDecodeError.corrupt }
        let metrics = TrajectoryCacheMetrics(
            trajectoryCount: trajectoryCount,
            segmentCount: totalSegmentCount,
            canonicalPointCount: canonicalCount,
            resolvedPointCount: resolvedCount,
            conflictCount: conflictCount,
            lodPointCount: 0,
            totalBytes: data.count,
            metadataBytes: metadataPrefixBytes + trajectoryBytes - pointIndexBytes,
            geometryBytes: geometryBytes,
            indexBytes: pointIndexBytes + resolvedIndexBytes,
            conflictBytes: conflictBytes,
            resolvedMetadataBytes: resolvedBytes - resolvedIndexBytes)
        return Decoded(
            resolution: TrajectoryResolution(
                trajectories: trajectories, conflicts: conflicts,
                points: resolvedPoints, comparedPairCount: comparedPairCount),
            canonicalPointCount: canonicalCount,
            metrics: metrics)
    }
}

private struct StringTable {
    private(set) var values: [String] = []
    private(set) var indices: [String: UInt32] = [:]

    mutating func register(_ value: String?) {
        guard let value, indices[value] == nil else { return }
        guard values.count < Int(UInt32.max) else { return }
        indices[value] = UInt32(values.count)
        values.append(value)
    }
}

private struct BinaryWriter {
    private(set) var data: Data

    init(capacity: Int) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    mutating func append(bytes: [UInt8]) { data.append(contentsOf: bytes) }

    mutating func append<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: Double) { append(value.bitPattern) }

    mutating func appendCount(_ value: Int) throws {
        guard value >= 0, value <= Int(UInt32.max) else {
            throw CacheDecodeError.corrupt
        }
        append(UInt32(value))
    }

    mutating func append(_ value: String) throws {
        let bytes = Array(value.utf8)
        try appendCount(bytes.count)
        data.append(contentsOf: bytes)
    }

    mutating func append(source: TrajectorySource) {
        data.append(Self.sourceCode(source))
    }

    mutating func append(optionalSource: TrajectorySource?) {
        data.append(optionalSource.map(Self.sourceCode) ?? UInt8.max)
    }

    mutating func appendStringIndex(_ value: String,
                                    table: StringTable) throws {
        guard let index = table.indices[value] else { throw CacheDecodeError.corrupt }
        append(index)
    }

    mutating func appendOptionalStringIndex(_ value: String?,
                                            table: StringTable) throws {
        guard let value else {
            append(UInt32.max)
            return
        }
        try appendStringIndex(value, table: table)
    }

    mutating func append(quality: TrajectoryQuality) throws {
        append(Int64(quality.pointCount))
        append(quality.duration)
        append(quality.maximumGap)
        append(quality.accuratePointRatio)
        append(quality.confidence)
    }

    mutating func append(_ point: TrajectoryPoint) throws {
        try append(point.id)
        append(point.latitude)
        append(point.longitude)
        append(point.timestamp.timeIntervalSince1970)
        append(source: point.source)
        var mask: UInt8 = 0
        if point.altitude != nil { mask |= 1 << 0 }
        if point.horizontalAccuracy != nil { mask |= 1 << 1 }
        if point.speed != nil { mask |= 1 << 2 }
        if point.course != nil { mask |= 1 << 3 }
        data.append(mask)
        if let value = point.altitude { append(value) }
        if let value = point.horizontalAccuracy { append(value) }
        if let value = point.speed { append(value) }
        if let value = point.course { append(value) }
    }

    private static func sourceCode(_ source: TrajectorySource) -> UInt8 {
        switch source {
        case .coreLocation: return 0
        case .healthWorkout: return 1
        case .imported: return 2
        case .inferred: return 3
        }
    }
}

private struct BinaryReader {
    let data: Data
    private(set) var offset = 0
    var isAtEnd: Bool { offset == data.count }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset <= data.count - count else {
            throw CacheDecodeError.corrupt
        }
        let result = Array(data[offset..<(offset + count)])
        offset += count
        return result
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw CacheDecodeError.corrupt }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32() throws -> UInt32 { try readInteger() }
    mutating func readInt64() throws -> Int64 { try readInteger() }
    mutating func readDouble() throws -> Double {
        Double(bitPattern: try readInteger() as UInt64)
    }

    mutating func readInt() throws -> Int {
        let value = try readInt64()
        guard let result = Int(exactly: value) else { throw CacheDecodeError.corrupt }
        return result
    }

    mutating func readCount(maximum: Int) throws -> Int {
        let value = Int(try readUInt32())
        guard value <= maximum else { throw CacheDecodeError.corrupt }
        return value
    }

    mutating func readIndex(count: Int) throws -> Int {
        let index = Int(try readUInt32())
        guard index < count else { throw CacheDecodeError.corrupt }
        return index
    }

    mutating func readString() throws -> String {
        let count = try readCount(maximum: data.count)
        guard offset <= data.count - count else { throw CacheDecodeError.corrupt }
        let value = String(decoding: data[offset..<(offset + count)], as: UTF8.self)
        offset += count
        return value
    }

    mutating func readString(from table: [String]) throws -> String {
        table[try readIndex(count: table.count)]
    }

    mutating func readOptionalString(from table: [String]) throws -> String? {
        let raw = try readUInt32()
        if raw == UInt32.max { return nil }
        let index = Int(raw)
        guard index < table.count else { throw CacheDecodeError.corrupt }
        return table[index]
    }

    mutating func readSource() throws -> TrajectorySource {
        guard let source = Self.source(code: try readUInt8()) else {
            throw CacheDecodeError.corrupt
        }
        return source
    }

    mutating func readOptionalSource() throws -> TrajectorySource? {
        let code = try readUInt8()
        if code == UInt8.max { return nil }
        guard let source = Self.source(code: code) else { throw CacheDecodeError.corrupt }
        return source
    }

    mutating func readQuality() throws -> TrajectoryQuality {
        let pointCount = try readInt()
        guard pointCount >= 0 else { throw CacheDecodeError.corrupt }
        return TrajectoryQuality(
            pointCount: pointCount,
            duration: try readDouble(), maximumGap: try readDouble(),
            accuratePointRatio: try readDouble(), confidence: try readDouble())
    }

    mutating func readTrajectoryPoint() throws -> TrajectoryPoint {
        let id = try readString()
        let latitude = try readDouble()
        let longitude = try readDouble()
        let timestamp = Date(timeIntervalSince1970: try readDouble())
        let source = try readSource()
        let mask = try readUInt8()
        guard mask & 0b1111_0000 == 0 else { throw CacheDecodeError.corrupt }
        let altitude = mask & (1 << 0) == 0 ? nil : try readDouble()
        let horizontalAccuracy = mask & (1 << 1) == 0 ? nil : try readDouble()
        let speed = mask & (1 << 2) == 0 ? nil : try readDouble()
        let course = mask & (1 << 3) == 0 ? nil : try readDouble()
        return TrajectoryPoint(
            id: id, latitude: latitude, longitude: longitude,
            timestamp: timestamp, altitude: altitude,
            horizontalAccuracy: horizontalAccuracy, speed: speed,
            course: course, source: source)
    }

    private mutating func readInteger<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        guard offset <= data.count - size else { throw CacheDecodeError.corrupt }
        let value: T = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        offset += size
        return T(littleEndian: value)
    }

    private static func source(code: UInt8) -> TrajectorySource? {
        switch code {
        case 0: return .coreLocation
        case 1: return .healthWorkout
        case 2: return .imported
        case 3: return .inferred
        default: return nil
        }
    }
}

// MARK: - Read-only v1 compatibility

private struct LegacyEnvelope: Codable {
    let schemaVersion: Int
    let geometryPresentationVersion: Int
    let dataRevision: Int
    let generatedAt: Date
    let canonicalPoints: [TrajectoryPoint]
    let trajectories: [LegacyCachedTrajectory]
    let conflicts: [TrajectoryConflict]
    let resolvedPoints: [LegacyCachedResolvedPoint]
    let comparedPairCount: Int

    func materialize() -> TrajectoryResolution? {
        func point(at index: Int) -> TrajectoryPoint? {
            canonicalPoints.indices.contains(index) ? canonicalPoints[index] : nil
        }
        let materializedTrajectories = trajectories.compactMap { $0.materialize(pointAt: point) }
        guard materializedTrajectories.count == trajectories.count else { return nil }
        let materializedPoints = resolvedPoints.compactMap { $0.materialize(pointAt: point) }
        guard materializedPoints.count == resolvedPoints.count else { return nil }
        return TrajectoryResolution(
            trajectories: materializedTrajectories, conflicts: conflicts,
            points: materializedPoints, comparedPairCount: comparedPairCount)
    }
}

private struct LegacyCachedTrajectory: Codable {
    let id: String
    let source: TrajectorySource
    let sourceIdentifier: String?
    let sessionID: String
    let startTime: Date
    let endTime: Date
    let activityType: String?
    let segments: [LegacyCachedSegment]
    let quality: TrajectoryQuality
    let confidence: Double
    let displayPriority: Int

    func materialize(pointAt: (Int) -> TrajectoryPoint?) -> Trajectory? {
        let values = segments.compactMap { $0.materialize(pointAt: pointAt) }
        guard values.count == segments.count else { return nil }
        return Trajectory(
            id: id, source: source, sourceIdentifier: sourceIdentifier,
            sessionID: sessionID, startTime: startTime, endTime: endTime,
            activityType: activityType, segments: values, quality: quality,
            confidence: confidence, displayPriority: displayPriority)
    }
}

private struct LegacyCachedSegment: Codable {
    let id: String
    let trajectoryID: String
    let sessionID: String
    let source: TrajectorySource
    let pointIndices: [Int]
    let startTime: Date
    let endTime: Date
    let quality: TrajectoryQuality

    func materialize(pointAt: (Int) -> TrajectoryPoint?) -> TrajectorySegment? {
        let points = pointIndices.compactMap(pointAt)
        guard points.count == pointIndices.count else { return nil }
        return TrajectorySegment(
            id: id, trajectoryID: trajectoryID, sessionID: sessionID,
            source: source, points: points, startTime: startTime,
            endTime: endTime, quality: quality)
    }
}

private struct LegacyCachedResolvedPoint: Codable {
    let trajectoryID: String
    let sessionID: String
    let segmentID: String
    let source: TrajectorySource
    let pointIndex: Int
    let confidence: Double
    let suppressedByTrajectoryID: String?
    let suppressedBySource: TrajectorySource?

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
