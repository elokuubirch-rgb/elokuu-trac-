import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case french = "fr"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }

    /// 语言选择器始终显示语言本名，避免切换后难以找回。
    var nativeName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .french: return "Français"
        }
    }

    /// 让系统级回退与应用内语言一致（single source of truth 的第二道保险）：
    /// 任何瞬时未继承 `.environment(\.locale)` 的视图 / 系统组件，
    /// 在快速切 Tab、滑动分页时会按 AppleLanguages 回退到应用语言，
    /// 而不是系统语言（避免闪现法语等系统语言界面）。
    static func syncAppleLanguages(_ rawValue: String) {
        guard AppLanguage(rawValue: rawValue) != nil else { return }
        UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
    }
}
