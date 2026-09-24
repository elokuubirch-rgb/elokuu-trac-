import XCTest
import SQLite3
@testable import LifeFootprints

final class StorageAuditDiagnosticsTests: XCTestCase {
    func testAuditReportsAggregatesWithoutModifyingDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageAuditTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("default.store")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let fixture = """
        CREATE TABLE ZWORKOUTROUTEPOINT (ZWORKOUTID TEXT, ZROUTEID TEXT);
        INSERT INTO ZWORKOUTROUTEPOINT VALUES ('workout', 'route'), ('workout', 'route'), ('legacy', NULL);
        """
        XCTAssertEqual(sqlite3_exec(database, fixture, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let before = try Data(contentsOf: url)

        let report = try StorageAuditDiagnostics.collect(databaseURL: url)
        XCTAssertEqual(report["readOnly"] as? Bool, true)
        let counts = try XCTUnwrap(report["tableCounts"] as? [String: Any])
        XCTAssertEqual(counts["ZWORKOUTROUTEPOINT"] as? Int64, 3)
        let summary = try XCTUnwrap((report["routeSummary"] as? [[String: Any]])?.first)
        XCTAssertEqual(summary["route_count"] as? Int64, 1)
        XCTAssertEqual(summary["missing_route_ids"] as? Int64, 1)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: report))
    }
}
