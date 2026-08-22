import Foundation

public struct ParsedMapSourceInput: Equatable, Sendable {
    public let urlTemplate: String
    public let suggestedName: String?
    public let suggestedAttribution: String?
    public let suggestedMaximumZoom: Int?

    public init(urlTemplate: String, suggestedName: String? = nil,
                suggestedAttribution: String? = nil, suggestedMaximumZoom: Int? = nil) {
        self.urlTemplate = urlTemplate
        self.suggestedName = suggestedName
        self.suggestedAttribution = suggestedAttribution
        self.suggestedMaximumZoom = suggestedMaximumZoom
    }
}

public enum MapSourceInputParser {
    /// 接受普通 URL、XYZ 模板或完整 iframe。MapTiler 地图预览地址
    /// 会自动转成 MapKit 可用的 512px XYZ 瓦片模板。
    public static func parse(_ input: String) -> ParsedMapSourceInput? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let src = firstMatch(in: value, pattern: #"(?i)src\s*=\s*["']([^"']+)["']"#) {
            value = src
        }
        value = value.replacingOccurrences(of: "&amp;", with: "&")

        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased() else {
            return ParsedMapSourceInput(urlTemplate: value)
        }

        if host == "api.maptiler.com" {
            let parts = components.path.split(separator: "/").map(String.init)
            if parts.count >= 2, parts[0] == "maps",
               let key = components.queryItems?.first(where: { $0.name == "key" })?.value,
               !key.isEmpty {
                let mapID = parts[1]
                let template = "https://api.maptiler.com/maps/\(mapID)/256/{z}/{x}/{y}@2x.png?key=\(key)"
                let displayName = mapID == "outdoor-v4" ? "专业等高线" : "MapTiler \(mapID)"
                return ParsedMapSourceInput(
                    urlTemplate: template,
                    suggestedName: displayName,
                    suggestedAttribution: "© MapTiler · © OpenStreetMap contributors",
                    suggestedMaximumZoom: 20)
            }
        }

        return ParsedMapSourceInput(urlTemplate: value)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
