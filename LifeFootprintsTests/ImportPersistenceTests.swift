import XCTest
import SwiftData
import MapKit
@testable import LifeFootprints

final class ImportPersistenceTests: XCTestCase {
    func testStreamingScalarCSVParserPreservesQuotesBOMAndCRLF() {
        let text = "\u{FEFF}latitude,longitude,time,name\r\n"
            + "31.2,121.4,2025-01-02 03:04,\"上海, 中国\"\r\n"
            + "31.3,121.5,2025-01-03,\"带\"\"引号\"\"\n地点\"\n"

        let result = CSVParser.parse(text)

        XCTAssertEqual(result.header, ["latitude", "longitude", "time", "name"])
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0][3], "上海, 中国")
        XCTAssertEqual(result.rows[1][3], "带\"引号\"\n地点")
    }

    func testFootprintImportBatchPolicyHasBoundedTransactions() {
        XCTAssertEqual(FootprintImportPersistencePolicy.batchCount(for: 0), 0)
        XCTAssertEqual(FootprintImportPersistencePolicy.batchCount(for: 1), 1)
        XCTAssertEqual(FootprintImportPersistencePolicy.batchCount(for: 5_000), 1)
        XCTAssertEqual(FootprintImportPersistencePolicy.batchCount(for: 5_001), 2)
        XCTAssertEqual(FootprintImportPersistencePolicy.batchCount(for: 143_056), 29)
    }

    func testIntegerDedupeGridPreservesDayAndNeighborSemantics() {
        var index = DedupeIndex()
        index.add(day: 19_000, lat: 31.2304, lon: 121.4737)

        XCTAssertTrue(index.hasNearby(day: 19_000, lat: 31.23041, lon: 121.47371,
                                      withinMeters: 50))
        XCTAssertFalse(index.hasNearby(day: 19_001, lat: 31.23041, lon: 121.47371,
                                       withinMeters: 50))
        XCTAssertFalse(index.hasNearby(day: 19_000, lat: 31.2404, lon: 121.4737,
                                       withinMeters: 50))
    }

    func testDotsSpatialIndexReturnsEveryVisiblePointWithoutFrequencyChanges() {
        let dots = [
            FootprintDot(id: 1, lat: 31.2304, lon: 121.4737, freq: 1),
            FootprintDot(id: 2, lat: 31.2314, lon: 121.4747, freq: 1),
            FootprintDot(id: 3, lat: 39.9042, lon: 116.4074, freq: 4),
        ]
        let overlay = FootprintDotsOverlay(dots: dots)
        let shanghai = MKMapPoint(CLLocationCoordinate2D(latitude: 31.2304,
                                                         longitude: 121.4737))
        let localRect = MKMapRect(x: shanghai.x - 10_000, y: shanghai.y - 10_000,
                                  width: 20_000, height: 20_000)

        let localFrequencyOne = overlay.mapPoints(
            frequencyIndex: 0, intersecting: localRect).filter(localRect.contains)
        let localFrequencyFour = overlay.mapPoints(
            frequencyIndex: 3, intersecting: localRect).filter(localRect.contains)
        let all = (0..<4).reduce(0) { count, frequency in
            count + overlay.mapPoints(
                frequencyIndex: frequency, intersecting: .world).count
        }

        XCTAssertEqual(localFrequencyOne.count, 2)
        XCTAssertTrue(localFrequencyFour.isEmpty)
        XCTAssertEqual(all, dots.count)
    }

    func testHundredThousandDotsSpatialIndexAvoidsPerTileFullScans() {
        let count = 100_000
        let dots = (0..<count).map { index in
            FootprintDot(
                id: index, lat: 31.2304,
                lon: 70 + Double(index) / Double(count - 1) * 70,
                freq: index % 4 + 1)
        }
        let overlay = FootprintDotsOverlay(dots: dots)
        let tileCount = 16
        let tileWidth = overlay.boundingMapRect.width / Double(tileCount)
        var indexedCandidateCount = 0

        for tile in 0..<tileCount {
            let rect = MKMapRect(
                x: overlay.boundingMapRect.minX + Double(tile) * tileWidth,
                y: overlay.boundingMapRect.minY,
                width: tileWidth, height: overlay.boundingMapRect.height)
            for frequency in 0..<4 {
                indexedCandidateCount += overlay.mapPoints(
                    frequencyIndex: frequency, intersecting: rect).count
            }
        }

        // 旧 renderer 在 16 个 tile 中扫描 1,600,000 次；索引只访问各 tile
        // 的实际 x 候选。边界点最多会同时进入相邻两个闭区间。
        XCTAssertLessThanOrEqual(indexedCandidateCount, count + tileCount)
        XCTAssertLessThan(indexedCandidateCount, count * tileCount / 10)
    }

    @MainActor
    func testBatchedImportPersistsAllDensePointsAcrossBatchBoundaries() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: FootprintPoint.self, configurations: configuration)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let drafts = (0..<10_123).map { index in
            FootprintDraft(
                latitude: 31 + Double(index % 1_000) * 0.000_001,
                longitude: 121 + Double(index / 1_000) * 0.000_001,
                timestamp: base.addingTimeInterval(Double(index)),
                source: FootprintSource.csv.rawValue)
        }

        let added = await FootprintStore.importDraftsInBackground(
            drafts, container: container, dense: true)

        XCTAssertEqual(added, drafts.count)
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FootprintPoint>()), drafts.count)
    }

    @MainActor
    func testBatchedImportRetainsSameDayFiftyMeterDedupeAcrossTransactions() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: FootprintPoint.self, configurations: configuration)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var drafts: [FootprintDraft] = []
        drafts.reserveCapacity(12_000)
        for index in 0..<6_000 {
            let timestamp = base.addingTimeInterval(Double(index) * 86_400)
            let point = FootprintDraft(
                latitude: 31.2304, longitude: 121.4737, timestamp: timestamp,
                source: FootprintSource.csv.rawValue)
            drafts.append(point)
            drafts.append(point)
        }

        let first = await FootprintStore.importDraftsInBackground(
            drafts, container: container)
        let second = await FootprintStore.importDraftsInBackground(
            drafts, container: container)

        XCTAssertEqual(first, 6_000)
        XCTAssertEqual(second, 0)
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FootprintPoint>()), 6_000)
    }
}
