import Foundation
import CoreLogic

func runImportIntegrityChecks() {
    let parsed = CSVParser.parse("latitude,longitude,time\n31,121,2026-09-11 08:00:00\n31,121,nonsense\n31,121,\n999,121,2026-09-11\n")
    let mapped = parsed.validatedPoints(CSVParser.smartMapping(parsed))
    check(mapped.points.count == 1, "导入-无效时间不会伪造为今天")
    check(mapped.issues.map(\.row) == [2, 3, 4], "导入-无效行可定位且不包含表头")
    check(mapped.issues.map(\.reason) == [.invalidTime, .missingTime, .invalidCoordinate],
          "导入-日期与坐标错误分类")
    var missing = CSVParser.smartMapping(parsed)
    missing.timeIndex = nil
    check(parsed.mapPoints(missing).points.isEmpty, "导入-未选择时间列不能伪造记录")
    check(CSVParser.parseDate("2026-02-30") == nil, "导入-不存在的日期拒绝")
    check(CSVParser.parseDate("2026-13-11") == nil, "导入-无效月份拒绝")
    check(CSVParser.parseDate("2026-09-11 garbage") == nil, "导入-日期尾随垃圾拒绝")
    check(CSVParser.parse("latitude,longitude,time\n31,121,\"broken").error != nil,
          "导入-未闭合引号不能当作成功解析")
    let offset = CSVParser.parseDate("2026-09-11T08:00:00+08:00")
    check(offset == CSVParser.parseDate("2026-09-11T00:00:00Z"), "导入-原始时区对应同一时刻")
    let p = FootprintDraft(latitude: 31, longitude: 121, timestamp: Date(timeIntervalSince1970: 10), source: "csv")
    var revisited = p
    revisited.timestamp = Date(timeIntervalSince1970: 20)
    var nearby = p
    nearby.longitude += 0.00001
    var segment = p
    segment.segmentID = "other"
    check(Set([p, p, revisited, nearby, segment].map(ImportPointIdentity.init)).count == 4,
          "导入-仅重复测量去重，折返近点和分段保留")
}
