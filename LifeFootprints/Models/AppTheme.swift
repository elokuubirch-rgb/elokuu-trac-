import SwiftUI

/// 足迹主题系统：足迹色与地图底色联动
enum AppTheme: String, CaseIterable, Identifiable {
    case crimson
    case arctic
    case neon
    case sunset
    case mono

    var id: String { rawValue }

    var name: String {
        switch self {
        case .crimson: return "Crimson · 绯红"
        case .arctic: return "Arctic · 冰蓝"
        case .neon: return "Neon · 霓虹"
        case .sunset: return "Sunset · 暮色"
        case .mono: return "Mono · 单色"
        }
    }

    var color: Color {
        switch self {
        case .crimson: return Color(red: 1.00, green: 0.23, blue: 0.31)
        case .arctic: return Color(red: 0.44, green: 0.79, blue: 1.00)
        case .neon: return Color(red: 0.00, green: 1.00, blue: 0.64)
        case .sunset: return Color(red: 1.00, green: 0.48, blue: 0.24)
        case .mono: return .white
        }
    }
}
