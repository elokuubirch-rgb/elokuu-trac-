import Foundation

/// Shared wording for scan/import outcomes; never label a partial save as complete.
enum ImportFeedback {
    static func text(_ key: String, _ values: CVarArg...) -> String {
        let language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "")
            ?? .simplifiedChinese
        let bundle = Bundle.main.path(forResource: language.rawValue, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? .main
        return String(format: bundle.localizedString(forKey: key, value: nil, table: nil),
                      locale: language.locale, arguments: values)
    }

    static func title(_ result: LocalImportResult) -> String {
        switch result.status {
        case .completed: return text("Import complete")
        case .failed: return text("Import incomplete")
        case .cancelled: return text("Import cancelled")
        }
    }

    static func summary(_ result: LocalImportResult, skipped: Int = 0) -> String {
        let counts = text("Added %lld · Updated %lld · Duplicates %lld · Skipped %lld",
                          result.added, result.updated, result.duplicates, result.invalid + skipped)
        switch result.status {
        case .completed: return counts
        case .failed: return counts + "\n" + text("Some records were not saved. Retry the same file; saved measurements will not be duplicated.")
        case .cancelled: return text("Local data was cleared. This earlier import was stopped; select the file again to start a new import.")
        }
    }
}
