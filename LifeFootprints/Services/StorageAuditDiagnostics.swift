#if DEBUG
import Foundation
import SQLite3

/// 显式诊断开关；数据库只读连接 + 单一读事务。只输出结构和汇总，不输出业务明细。
enum StorageAuditDiagnostics {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["FP_STORAGE_AUDIT"] == "1" else { return }
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            let database = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("default.store")
            let output = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("storage_audit.json")
            do {
                let report = try collect(databaseURL: database)
                let data = try JSONSerialization.data(
                    withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output, options: .atomic)
                appLog.info("[StorageAudit] 汇总导出完成")
            } catch {
                appLog.error("[StorageAudit] 只读审计失败：\(error.localizedDescription)")
            }
        }
    }

    static func collect(databaseURL: URL) throws -> [String: Any] {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &connection,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database = connection else {
            if let connection { sqlite3_close(connection) }
            throw NSError(domain: "StorageAudit", code: 1)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        _ = try query("PRAGMA query_only = ON", database: database)
        _ = try query("BEGIN", database: database)
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }

        var result: [String: Any] = [
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "readOnly": sqlite3_db_readonly(database, "main") == 1,
            "quickCheck": try query("PRAGMA quick_check", database: database),
            "pageSize": try query("PRAGMA page_size", database: database),
            "pageCount": try query("PRAGMA page_count", database: database),
            "freelistCount": try query("PRAGMA freelist_count", database: database)
        ]
        let schema = try query(
            "SELECT type, name, tbl_name FROM sqlite_schema WHERE type IN ('table','index') ORDER BY type,name",
            database: database)
        result["schema"] = schema
        var counts: [String: Any] = [:]
        for table in schema where table["type"] as? String == "table" {
            guard let name = table["name"] as? String else { continue }
            let quoted = name.replacingOccurrences(of: "\"", with: "\"\"")
            counts[name] = try query("SELECT COUNT(*) AS rows FROM \"\(quoted)\"", database: database).first?["rows"]
        }
        result["tableCounts"] = counts
        do {
            result["pageUsage"] = try query(
                "SELECT name, COUNT(*) AS pages, SUM(pgsize) AS allocated_bytes, SUM(payload) AS payload_bytes, SUM(unused) AS unused_bytes FROM dbstat GROUP BY name ORDER BY allocated_bytes DESC",
                database: database)
        } catch {
            // 部分 iOS SQLite 未编译 dbstat；明确报告缺失，不能用表行数冒充页占用。
            result["pageUsageUnavailable"] = error.localizedDescription
        }
        if counts["ZWORKOUTROUTEPOINT"] != nil {
            result["routePointColumns"] = try query("PRAGMA table_info(ZWORKOUTROUTEPOINT)", database: database)
            result["routeSummary"] = try query(
                "SELECT COUNT(*) AS point_count, COUNT(DISTINCT ZWORKOUTID) AS workout_count, COUNT(DISTINCT ZROUTEID) AS route_count, SUM(ZROUTEID IS NULL) AS missing_route_ids FROM ZWORKOUTROUTEPOINT",
                database: database)
            result["routePointDistribution"] = try query(
                "SELECT COUNT(*) AS routes, MIN(n) AS minimum, MAX(n) AS maximum, AVG(n) AS average FROM (SELECT COUNT(*) AS n FROM ZWORKOUTROUTEPOINT WHERE ZROUTEID IS NOT NULL GROUP BY ZROUTEID)",
                database: database)
        }
        return result
    }

    private static func query(_ sql: String, database: OpaquePointer) throws -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw error(database)
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String: Any]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw error(database) }
            var row: [String: Any] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, index)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, index)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, index))
                default: row[name] = NSNull()
                }
            }
            rows.append(row)
        }
    }

    private static func error(_ database: OpaquePointer) -> NSError {
        NSError(domain: "StorageAudit", code: Int(sqlite3_errcode(database)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
    }
}
#endif
