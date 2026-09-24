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
        MapStartupDiagnostics.shared.mark(.processStarted)
        #if DEBUG
        let fp = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("FP_") }
        if fp["FP_UI_TEST"] == "1", fp["FP_PRESERVE_USER_PREFERENCES"] != "1" {
            UserDefaults.standard.set(true, forKey: "onboarded")
            UserDefaults.standard.set(false, forKey: "bgFootprints")
            UserDefaults.standard.set(false,
                                      forKey: HealthKitSyncCoordinator.automaticSyncEnabledKey)
        }
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
            #if DEBUG && targetEnvironment(simulator)
            // 删除回归使用隔离内存库，避免多次测试消费同一批照片后再也没有下一组。
            let isolatedReviewTest = fp["FP_UI_TEST"] == "1"
                && fp["FP_ISOLATED_REVIEW_STORE"] == "1"
            if isolatedReviewTest {
                ReviewHistoryStore.reset()
                ReviewSessionPersistence.reset()
                UserDefaults.standard.set(10, forKey: "reviewGroupSize")
                container = try ModelContainer(
                    for: FootprintPoint.self, PhotoRecord.self, WorkoutRecord.self,
                    WorkoutRouteRecord.self, WorkoutRoutePoint.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            } else {
                container = try ModelContainer(for: FootprintPoint.self, PhotoRecord.self,
                                               WorkoutRecord.self, WorkoutRouteRecord.self,
                                               WorkoutRoutePoint.self)
            }
            #else
            container = try ModelContainer(for: FootprintPoint.self, PhotoRecord.self,
                                           WorkoutRecord.self, WorkoutRouteRecord.self,
                                           WorkoutRoutePoint.self)
            #endif
        } catch {
            fatalError("无法初始化数据容器: \(error)")
        }

        // 自动轨迹经质量过滤后小批量原子入库；失败批次由 writer 保留并重试。
        TrackPointBatchWriter.shared.configure(container: container)
        #if DEBUG
        StorageAuditDiagnostics.runIfRequested()
        #endif
        // 若用户之前开启过后台足迹，冷启动或系统定位唤醒时立即恢复监听。
        LocationService.shared.restoreBackgroundMonitoring()
        // 用户完成过 HealthKit 授权后，冷启动恢复 observer 并执行一次锚点增量同步。
        // 真机性能审计需要把既有数据加载与一次新的 HealthKit 写入分开测量；
        // 该 DEBUG 环境变量不改用户偏好，也不会进入正式包行为。
        #if DEBUG
        if ProcessInfo.processInfo.environment["FP_SKIP_HEALTH_RESTORE"] != "1" {
            HealthKitSyncCoordinator.shared.restoreIfEnabled(container: container)
        }
        #else
        HealthKitSyncCoordinator.shared.restoreIfEnabled(container: container)
        #endif
    }

    var body: some Scene {
        #if DEBUG
        let _ = PerformanceDiagnostics.event("LifeFootprintsApp.body")
        #endif
        WindowGroup {
            Group {
                #if DEBUG
                if TestHooks.performanceLargeScaleSeed {
                    PerformanceLargeScaleSeedView(container: container)
                } else if onboarded {
                    MainTabView()
                } else {
                    OnboardingView { onboarded = true }
                }
                #else
                if onboarded {
                    MainTabView()
                } else {
                    OnboardingView { onboarded = true }
                }
                #endif
            }
            .environment(\.locale, appLanguage.locale)
            // SwiftUI 的部分系统容器会缓存本地化文本，语言切换时重建根视图。
            .id(appLanguage.rawValue)
        }
        .modelContainer(container)
    }
}

#if DEBUG
/// 隔离模拟器造数入口。完成后刻意不进入产品页面，确保后续冷启动审计在
/// 全新进程、无造数峰值残留的条件下执行。
private struct PerformanceLargeScaleSeedView: View {
    let container: ModelContainer
    @State private var status = "正在生成 182 万点性能夹具…"

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(status)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .task {
            let succeeded = await TestHooks.seedLargeScalePerformanceData(into: container)
            status = succeeded
                ? "性能夹具已完成，可以终止进程并开始冷启动审计"
                : "性能夹具生成失败；已停止，未进入产品页面"
        }
    }
}
#endif
