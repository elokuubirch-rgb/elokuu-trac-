import SwiftUI
import SwiftData
import os

let appLog = Logger(subsystem: "com.footprints.LifeFootprints", category: "test")

@main
struct LifeFootprintsApp: App {
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.simplifiedChinese.rawValue

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .simplifiedChinese
    }

    /// 共享容器：后台足迹通知的入库观察者使用
    private let container: ModelContainer

    init() {
        #if DEBUG
        let fp = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("FP_") }
        if let language = fp["FP_LANGUAGE"], AppLanguage(rawValue: language) != nil {
            UserDefaults.standard.set(language, forKey: "appLanguage")
        }
        appLog.info("[App] 测试环境变量: \(fp)")
        appLog.info("[App] onboarded=\(UserDefaults.standard.bool(forKey: "onboarded"))")
        #endif

        // 单一语言来源：让系统级回退（AppleLanguages）始终跟随应用内设置。
        // 快速切 Tab / 分页滑动时，任何未继承 environment(\.locale) 的视图
        // 回退到应用语言，而不是系统语言（此前会闪现法语界面）。
        let languageRaw = UserDefaults.standard.string(forKey: "appLanguage")
            ?? AppLanguage.simplifiedChinese.rawValue
        AppLanguage.syncAppleLanguages(languageRaw)
        appLog.info("[App] 语言=\(languageRaw)")

        do {
            container = try ModelContainer(for: FootprintPoint.self, PhotoRecord.self,
                                           WorkoutRecord.self, WorkoutRouteRecord.self,
                                           WorkoutRoutePoint.self)
        } catch {
            fatalError("无法初始化数据容器: \(error)")
        }

        // 低功耗后台足迹：捕获到访问/重大位置变化 → 智能融合入库（时间+空间去重）
        let box = ContainerBox(container)
        NotificationCenter.default.addObserver(forName: .footprintsCaptured,
                                               object: nil, queue: nil) { note in
            guard let draft = note.object as? FootprintDraft else { return }
            let c = box.container
            Task.detached(priority: .utility) {
                _ = await FootprintStore.importBackgroundDraft(draft, container: c)
            }
        }
        // 若用户之前开启过后台足迹，冷启动或系统定位唤醒时立即恢复监听。
        LocationService.shared.restoreBackgroundMonitoring()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if onboarded {
                    MainTabView()
                } else {
                    OnboardingView { onboarded = true }
                }
            }
            .environment(\.locale, appLanguage.locale)
            // SwiftUI 的部分系统容器会缓存本地化文本，语言切换时重建根视图。
            .id(appLanguage.rawValue)
        }
        .modelContainer(container)
    }
}

/// 把容器带进通知闭包的小盒子（避免捕获 struct self）
private final class ContainerBox {
    let container: ModelContainer
    init(_ container: ModelContainer) {
        self.container = container
    }
}
