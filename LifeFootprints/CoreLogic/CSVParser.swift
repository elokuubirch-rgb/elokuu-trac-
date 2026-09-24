import Foundation

/// CSV 解析结果
public struct CSVParseResult: Sendable {
    public var header: [String] = []
    public var rows: [[String]] = []
    public var error: String?

    public init() {}
}

/// 列映射（索引从 0 开始；nil = 不导入该列）
public struct ColumnMapping: Equatable, Sendable {
    public var latIndex: Int?
    public var lonIndex: Int?
    public var timeIndex: Int?
    public var nameIndex: Int?
    public var sourceCoordinateSystem: CoordinateReferenceSystem

    public init(latIndex: Int? = nil, lonIndex: Int? = nil, timeIndex: Int? = nil,
                nameIndex: Int? = nil,
                sourceCoordinateSystem: CoordinateReferenceSystem = .unknown) {
        self.latIndex = latIndex
        self.lonIndex = lonIndex
        self.timeIndex = timeIndex
        self.nameIndex = nameIndex
        self.sourceCoordinateSystem = sourceCoordinateSystem
    }
}

/// 极简 CSV 解析器：支持引号、"" 转义、CRLF、UTF-8 BOM
public enum CSVParser {

    public static func parse(_ text: String) -> CSVParseResult {
        var result = CSVParseResult()
        var field = ""
        var row: [String] = []
        var inQuotes = false
        // 注意：必须按 UnicodeScalar 迭代，不能用 String 的 Character——
        // Unicode 把 CRLF 视为单个字素簇（grapheme cluster），Character 会把
        // \r\n 打包成一个字符，导致 \r 与 \n 的 case 都无法命中。
        // 直接使用迭代器，避免 12MB CSV 被复制成一个百 MB 级 UnicodeScalar 数组。
        var iterator = text.unicodeScalars.makeIterator()
        var current = iterator.next()
        if current?.value == 0xFEFF { current = iterator.next() }

        while let s = current {
            if inQuotes {
                if s.value == 34 {
                    let next = iterator.next()
                    if next?.value == 34 {
                        field.append("\"")
                        current = iterator.next()
                    } else {
                        inQuotes = false
                        current = next
                    }
                } else {
                    field.unicodeScalars.append(s)
                    current = iterator.next()
                }
                continue
            }
            switch s.value {
            case 34: // "
                inQuotes = true
                current = iterator.next()
            case 44: // ,
                row.append(field)
                field = ""
                current = iterator.next()
            case 10: // \n
                row.append(field)
                field = ""
                finishRow(&result, &row)
                current = iterator.next()
            case 13: // \r
                row.append(field)
                field = ""
                finishRow(&result, &row)
                let next = iterator.next()
                current = next?.value == 10 ? iterator.next() : next
            default:
                field.unicodeScalars.append(s)
                current = iterator.next()
            }
        }
        if inQuotes {
            result.error = "CSV contains an unclosed quoted field."
            return result
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            finishRow(&result, &row)
        }
        return result
    }

    private static func finishRow(_ result: inout CSVParseResult, _ row: inout [String]) {
        let trimmed = row.map { $0.trimmingCharacters(in: .whitespaces) }
        if result.header.isEmpty && result.rows.isEmpty && looksLikeHeader(trimmed) {
            result.header = trimmed
            row = []
            return
        }
        if trimmed.allSatisfy({ $0.isEmpty }) {
            row = []
            return
        }
        result.rows.append(trimmed)
        row = []
    }

    /// 首行是否为表头（列名「包含」关键词即认定，兼容 latitude/longitude/dataTime 等变体）
    private static func looksLikeHeader(_ row: [String]) -> Bool {
        let keywords = ["lat", "lon", "lng", "time", "date", "经度", "纬度", "时间", "日期"]
        return row.contains { cell in
            let c = cell.lowercased().trimmingCharacters(in: .whitespaces)
            return !c.isEmpty && keywords.contains { c.contains($0) }
        }
    }

    /// 时间解析：ISO8601 + 常见格式 + Unix 时间戳（秒/毫秒）。
    /// DateFormatter 走缓存（创建成本高，14 万行逐条新建会慢到不可用），NSLock 保护跨线程。
    public static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        // Unix 时间戳：秒（1e9~4.2e9）或毫秒（1e12~4.2e15）
        if let n = Double(t) {
            if (1_000_000_000...4_200_000_000).contains(n) {
                return Date(timeIntervalSince1970: n)
            }
            if (1_000_000_000_000...4_200_000_000_000).contains(n) {
                return Date(timeIntervalSince1970: n / 1000)
            }
        }
        if let d = DateFormatCache.shared.isoDate(t) { return d }
        for f in dateFormats {
            if let d = DateFormatCache.shared.date(t, format: f) { return d }
        }
        return nil
    }

    // MARK: - 智能列映射（表头关键词 + 数据嗅探）

    /// 表头关键词映射（中英文常见列名）
    public static func headerMapping(_ header: [String]) -> ColumnMapping {
        func find(_ keys: [String]) -> Int? {
            header.firstIndex { cell in
                keys.contains { $0.caseInsensitiveCompare(cell.trimmingCharacters(in: .whitespaces)) == .orderedSame }
            }
        }
        return ColumnMapping(
            latIndex: find(["lat", "latitude", "纬度", "y"]),
            lonIndex: find(["lon", "lng", "long", "longitude", "经度", "x"]),
            timeIndex: find(["time", "date", "datetime", "timestamp", "datatime", "时间", "日期"]),
            nameIndex: find(["name", "title", "city", "地点", "名称", "城市", "地址", "位置"]))
    }

    /// 数据嗅探：无表头/表头不认识时，按列数据特征识别（范围/类型统计）
    public static func sniffMapping(_ result: CSVParseResult) -> ColumnMapping {
        let sample = Array(result.rows.prefix(200))
        guard !sample.isEmpty, let width = sample.map({ $0.count }).max(), width > 0 else {
            return ColumnMapping()
        }
        var numericCount = [Int](repeating: 0, count: width)
        var nonEmptyCount = [Int](repeating: 0, count: width)
        var minV = [Double](repeating: .greatestFiniteMagnitude, count: width)
        var maxV = [Double](repeating: -.greatestFiniteMagnitude, count: width)
        var timeHit = [Int](repeating: 0, count: width)
        var epochHit = [Int](repeating: 0, count: width)
        var textHit = [Int](repeating: 0, count: width)

        for row in sample {
            for i in 0..<width {
                let cell = i < row.count ? row[i].trimmingCharacters(in: .whitespaces) : ""
                guard !cell.isEmpty else { continue }
                nonEmptyCount[i] += 1
                if let v = Double(cell) {
                    numericCount[i] += 1
                    minV[i] = min(minV[i], v)
                    maxV[i] = max(maxV[i], v)
                    if (1_000_000_000...4_200_000_000_000).contains(v) {
                        epochHit[i] += 1
                    }
                } else {
                    if parseDate(cell) != nil {
                        timeHit[i] += 1
                    } else {
                        textHit[i] += 1
                    }
                }
            }
        }

        // 数值占比 ≥80% 视为数值列（容忍个别脏行）
        func mostlyNumeric(_ i: Int) -> Bool {
            nonEmptyCount[i] > 0 && Double(numericCount[i]) >= Double(nonEmptyCount[i]) * 0.8
        }
        func validLat(_ i: Int) -> Bool { mostlyNumeric(i) && minV[i] >= -90 && maxV[i] <= 90 && minV[i] != maxV[i] }
        func validLon(_ i: Int) -> Bool { mostlyNumeric(i) && minV[i] >= -180 && maxV[i] <= 180 && minV[i] != maxV[i] }
        // 中国范围优先（一生足迹等国内 App 的数据几乎都落在国内）
        let chinaLat = (0..<width).filter { validLat($0) && minV[$0] >= 3 && maxV[$0] <= 54 }
        let chinaLon = (0..<width).filter { validLon($0) && minV[$0] >= 73 && maxV[$0] <= 136 }

        var lat = chinaLat.first ?? (0..<width).filter(validLat).first
        var lon = chinaLon.first ?? (0..<width).filter(validLon).first
        // 冲突处理：同一列不能既当纬度又当经度
        if let a = lat, let b = lon, a == b {
            let others = (0..<width).filter { $0 != a && (validLat($0) || validLon($0)) }
            if others.isEmpty {
                lon = nil
            } else if chinaLat.contains(a) && !chinaLon.contains(a) {
                lon = others.first
            } else {
                lat = others.first
            }
        }

        var time: Int? = nil
        let halfCount = Double(sample.count) * 0.5
        for i in 0..<width {
            let hits = timeHit[i] + epochHit[i]
            if Double(hits) > halfCount {
                time = i
                break
            }
        }

        var name: Int? = nil
        var bestText = 0
        for i in 0..<width where i != time && textHit[i] > bestText {
            bestText = textHit[i]
            name = i
        }

        return ColumnMapping(latIndex: lat, lonIndex: lon, timeIndex: time, nameIndex: name)
    }

    /// 智能映射：表头优先，缺失部分用数据嗅探补齐
    public static func smartMapping(_ result: CSVParseResult) -> ColumnMapping {
        var m = headerMapping(result.header)
        if m.latIndex == nil || m.lonIndex == nil || m.timeIndex == nil {
            let s = sniffMapping(result)
            m.latIndex = m.latIndex ?? s.latIndex
            m.lonIndex = m.lonIndex ?? s.lonIndex
            m.timeIndex = m.timeIndex ?? s.timeIndex
            m.nameIndex = m.nameIndex ?? s.nameIndex
        }
        return m
    }

    private static let dateFormats = [
        "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd",
        "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyy/MM/dd"
    ]
}

/// 线程安全的日期格式缓存
final class DateFormatCache {
    static let shared = DateFormatCache()
    private let lock = NSLock()
    private var cache: [String: DateFormatter] = [:]
    private let iso = ISO8601DateFormatter()

    func isoDate(_ s: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return iso.date(from: s)
    }

    func date(_ s: String, format: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        if let df = cache[format] {
            df.timeZone = .current
            return df.date(from: s)
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.isLenient = false
        df.timeZone = .current
        df.dateFormat = format
        cache[format] = df
        return df.date(from: s)
    }
}

extension CSVParseResult {
    /// 按映射把行转换为足迹草稿；非法坐标行跳过并计数
    public func mapPoints(_ mapping: ColumnMapping) -> (points: [FootprintDraft], skipped: Int) {
        let result = validatedPoints(mapping)
        return (result.points, result.issues.count)
    }

    /// Missing/invalid measurement times are never replaced with the import time.
    public func validatedPoints(_ mapping: ColumnMapping) -> CSVMappingResult {
        var result = CSVMappingResult()
        guard error == nil else { return result }
        for (index, row) in rows.enumerated() {
            let rowNumber = index + 1 // Data row, excluding the optional header.
            guard let latIdx = mapping.latIndex, row.indices.contains(latIdx),
                  let lonIdx = mapping.lonIndex, row.indices.contains(lonIdx),
                  let lat = Double(row[latIdx].trimmingCharacters(in: .whitespaces)),
                  let lon = Double(row[lonIdx].trimmingCharacters(in: .whitespaces)),
                  GeoMath.isValid(latitude: lat, longitude: lon) else {
                result.issues.append(.init(row: rowNumber, reason: .invalidCoordinate))
                continue
            }
            guard let t = mapping.timeIndex, row.indices.contains(t),
                  !row[t].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                result.issues.append(.init(row: rowNumber, reason: .missingTime))
                continue
            }
            guard let time = CSVParser.parseDate(row[t]) else {
                result.issues.append(.init(row: rowNumber, reason: .invalidTime))
                continue
            }
            let name: String? = mapping.nameIndex.flatMap { row.indices.contains($0) ? row[$0] : nil }
            let normalized = CoordinateTransform.normalize(
                latitude: lat, longitude: lon,
                sourceSystem: mapping.sourceCoordinateSystem)
            result.points.append(FootprintDraft(
                latitude: normalized.normalized.latitude,
                longitude: normalized.normalized.longitude,
                timestamp: time,
                source: FootprintSource.csv.rawValue,
                city: name,
                rawLatitude: normalized.raw.latitude,
                rawLongitude: normalized.raw.longitude,
                sourceCoordinateSystem: normalized.sourceSystem,
                coordinateTransformVersion: normalized.transformVersion
            ))
        }
        return result
    }
}

extension CSVParseResult {
    /// Raw, timed observations for diagnosis. No coordinate conversion is performed here.
    public func coordinateObservations(_ mapping: ColumnMapping,
                                       limit: Int = 2_000) -> [TimedCoordinateObservation] {
        guard error == nil, let latIndex = mapping.latIndex,
              let lonIndex = mapping.lonIndex, let timeIndex = mapping.timeIndex,
              limit > 0 else { return [] }
        let step = max(1, rows.count / limit)
        var observations: [TimedCoordinateObservation] = []
        observations.reserveCapacity(min(limit, rows.count))
        var index = 0
        while index < rows.count, observations.count < limit {
            let row = rows[index]
            if row.indices.contains(latIndex), row.indices.contains(lonIndex),
               row.indices.contains(timeIndex),
               let latitude = Double(row[latIndex].trimmingCharacters(in: .whitespaces)),
               let longitude = Double(row[lonIndex].trimmingCharacters(in: .whitespaces)),
               GeoMath.isValid(latitude: latitude, longitude: longitude),
               let timestamp = CSVParser.parseDate(row[timeIndex]) {
                observations.append(TimedCoordinateObservation(
                    latitude: latitude, longitude: longitude, timestamp: timestamp))
            }
            index += step
        }
        return observations
    }
}

public struct CSVMappingResult: Sendable {
    public struct Issue: Equatable, Sendable {
        public enum Reason: String, Sendable { case invalidCoordinate, missingTime, invalidTime }
        public let row: Int
        public let reason: Reason
    }
    public var points: [FootprintDraft] = []
    public var issues: [Issue] = []
    public init() {}
}
