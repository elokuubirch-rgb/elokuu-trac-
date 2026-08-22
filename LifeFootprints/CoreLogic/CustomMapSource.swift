import Foundation

public enum MapTileScheme: String, Codable, CaseIterable, Sendable {
    case xyz
    case tms
}

public struct CustomMapSource: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var urlTemplate: String
    public var scheme: MapTileScheme
    public var minimumZoom: Int
    public var maximumZoom: Int
    public var attribution: String

    public init(id: UUID = UUID(), name: String, urlTemplate: String,
                scheme: MapTileScheme = .xyz, minimumZoom: Int = 0,
                maximumZoom: Int = 19, attribution: String) {
        self.id = id
        self.name = name
        self.urlTemplate = urlTemplate
        self.scheme = scheme
        self.minimumZoom = minimumZoom
        self.maximumZoom = maximumZoom
        self.attribution = attribution
    }
}

public enum CustomMapSourceValidator {
    /// 返回 nil 表示可安全作为通用 XYZ/TMS 源使用。
    public static func validationError(for source: CustomMapSource) -> String? {
        guard !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "请填写地图源名称"
        }
        let template = source.urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard template.lowercased().hasPrefix("https://") else {
            return "仅支持 HTTPS 地图源"
        }
        guard template.contains("{z}"), template.contains("{x}"), template.contains("{y}") else {
            return "URL 必须包含 {z}、{x}、{y}"
        }
        let probe = template
            .replacingOccurrences(of: "{z}", with: "1")
            .replacingOccurrences(of: "{x}", with: "1")
            .replacingOccurrences(of: "{y}", with: "1")
            .replacingOccurrences(of: "{s}", with: "a")
            .replacingOccurrences(of: "{r}", with: "")
        guard let components = URLComponents(string: probe), let host = components.host else {
            return "URL 格式无效"
        }
        let normalizedHost = host.lowercased()
        let forbiddenGoogleHosts = ["google.com", "googleapis.com", "gstatic.com"]
        if forbiddenGoogleHosts.contains(where: {
            normalizedHost == $0 || normalizedHost.hasSuffix(".\($0)")
        }) {
            return "Google 地图不能作为通用瓦片导入，请使用官方 Maps Platform"
        }
        guard (0...22).contains(source.minimumZoom),
              (0...22).contains(source.maximumZoom),
              source.minimumZoom <= source.maximumZoom else {
            return "缩放层级必须在 0–22 之间"
        }
        guard !source.attribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "请填写数据来源署名"
        }
        return nil
    }
}
