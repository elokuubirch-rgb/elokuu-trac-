import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

/// 设置只负责配置与维护入口；数据规模和来源统计留给 Statistics。
struct SettingsScreen: View {
    @Environment(\.modelContext) private var context
    @AppStorage("theme") private var themeRaw = AppTheme.crimson.rawValue
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.simplifiedChinese.rawValue
    @AppStorage("reviewRecentDedupEnabled") private var reviewRecentDedupEnabled = true
    @AppStorage(HealthKitSyncCoordinator.automaticSyncEnabledKey)
    private var healthAutomaticSync = false

    @State private var busyText: String?
    @State private var scanProgress: Double?
    @State private var resultAlert: SettingsResultAlert?
    @State private var showImporter = false
    @State private var csvImport: CSVImportPresentation?
    @State private var showClearConfirm = false
    @State private var showClearTrajectoryCacheConfirm = false
    @State private var exportDocument: ExportDocument?
    @State private var customMapSources: [CustomMapSource] = []
    @State private var locationService = LocationService.shared
    @State private var trajectoryCacheSnapshot =
        PersistentTrajectoryCache.shared.diskSnapshot()

    private var theme: AppTheme { AppTheme(rawValue: themeRaw) ?? .crimson }
    private var language: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .simplifiedChinese
    }

    var body: some View {
        #if DEBUG
        let _ = PerformanceDiagnostics.event("SettingsScreen.body")
        #endif
        NavigationStack {
            Form {
                automaticRecordingSection
                reviewSection
                mapSection
                dataBackupSection
                cacheSection
                generalSection
                dataManagementSection
            }
            .navigationTitle("设置")
            .listSectionSpacing(.custom(26))
            .overlay { operationOverlay }
            .alert(item: $resultAlert) { result in
                Alert(title: Text(result.title), message: Text(result.message),
                      dismissButton: .default(Text("好")))
            }
            .alert("清除所有本地数据？", isPresented: $showClearConfirm) {
                Button("取消", role: .cancel) {}
                Button("清除所有数据", role: .destructive) { resetAllLocalData() }
            } message: {
                Text("这会删除 Trace 保存在本机的照片索引、足迹、运动路线、回顾记录、导入数据以及相关缓存。\n\n不会删除系统相册中的原始照片，也不会删除 Apple 健康中的原始数据。")
            }
            .alert("清理轨迹缓存？", isPresented: $showClearTrajectoryCacheConfirm) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) { clearTrajectoryCache() }
            } message: {
                Text("不会删除足迹、照片或运动记录。下次打开地图时可能需要重新生成轨迹缓存。")
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .data],
                          allowsMultipleSelection: false,
                          onCompletion: handleImport)
            .sheet(item: $csvImport) { presentation in
                CSVImportView(result: presentation.result, importToken: presentation.token) { saved, skipped in
                    resultAlert = SettingsResultAlert(
                        title: ImportFeedback.title(saved),
                        message: ImportFeedback.summary(saved, skipped: skipped))
                    csvImport = nil
                }
            }
            .sheet(item: $exportDocument) { document in
                ActivityShareSheet(items: [document.url])
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            #if DEBUG
            PerformanceDiagnostics.event("SettingsScreen.onAppear")
            PerformanceDiagnostics.endTransition("Stats->Settings")
            #endif
            customMapSources = MapSourceStore.load()
            refreshTrajectoryCacheSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mapSourcesChanged)) { _ in
            customMapSources = MapSourceStore.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .localDataReset)) { _ in
            csvImport = nil
        }
        .onDisappear {
            #if DEBUG
            PerformanceDiagnostics.event("SettingsScreen.onDisappear")
            PerformanceDiagnostics.endTransition("Settings->Stats")
            #endif
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var automaticRecordingSection: some View {
        Section("自动记录") {
            Toggle(isOn: Binding(
                get: { locationService.isBackgroundLocationEnabled },
                set: { locationService.setBackgroundFootprints($0) }
            )) {
                SettingsLabel(
                    "后台位置",
                    subtitle: locationService.isBackgroundLocationEnabled
                        ? "已开启，持续记录；移动时自动提高精度" : "关闭")
            }
            .accessibilityIdentifier("background-location-toggle")

            SettingsLabel(
                "定位精度", subtitle: "系统位置授权状态",
                value: LocationService.shared.hasFullAccuracy ? "精确" : "大致")

            SettingsLabel("运行状态", value: backgroundRuntimeText)

            SettingsLabel("后台刷新", value: backgroundRefreshText)

            SettingsLabel("最近位置回调", value: lastLocationCallbackText)

            Toggle(isOn: Binding(
                get: { healthAutomaticSync },
                set: { updateHealthAutomaticSync($0) }
            )) {
                SettingsLabel("自动同步 Apple 健康", subtitle: "自动同步运动路线")
            }
            .disabled(!HealthKitService.isAvailable || busyText != nil)
            .accessibilityIdentifier("health-auto-sync-toggle")
        }
    }

    private var backgroundRuntimeText: String {
        switch locationService.backgroundRuntimeState {
        case .disabled:
            return String(localized: "已关闭")
        case .permissionRequired:
            return String(localized: "需要“始终”位置权限")
        case .foreground:
            return String(localized: "前台定位")
        case .backgroundHighAccuracy:
            return String(localized: "后台高精度")
        case .backgroundLowPower:
            return String(localized: "后台低功耗")
        case .recovering:
            return String(localized: "正在恢复")
        }
    }

    private var backgroundRefreshText: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:
            return String(localized: "允许")
        case .denied:
            return String(localized: "关闭")
        case .restricted:
            return String(localized: "受限")
        @unknown default:
            return String(localized: "受限")
        }
    }

    private var lastLocationCallbackText: String {
        guard let date = locationService.lastLocationCallbackAt else {
            return String(localized: "尚未收到")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private var reviewSection: some View {
        Section("回顾") {
            Toggle(isOn: $reviewRecentDedupEnabled) {
                SettingsLabel("近期不重复回顾", subtitle: "减少近期已经看过的照片再次出现")
            }
        }
    }

    @ViewBuilder
    private var mapSection: some View {
        Section("地图") {
            NavigationLink {
                MapSourceManagementView()
            } label: {
                SettingsLabel("自定义地图源", subtitle: "添加或管理自定义地图样式",
                              value: "\(customMapSources.count) 个")
            }
        }
    }

    @ViewBuilder
    private var dataBackupSection: some View {
        Section("数据与备份") {
            Button { rescan() } label: {
                SettingsLabel("重新扫描相册", subtitle: "更新 Trace 中的照片索引",
                              showsChevron: true)
            }
            .disabled(busyText != nil)
            .accessibilityIdentifier("rescan-photos")

            Button { chooseImportFile() } label: {
                SettingsLabel("导入 CSV 文件", subtitle: "从其他服务导入足迹数据",
                              showsChevron: true)
            }
            .disabled(busyText != nil)
            .accessibilityIdentifier("import-csv")

            Button { exportCSV() } label: {
                SettingsLabel("导出备份", subtitle: "导出 Trace 保存的数据",
                              showsChevron: true)
            }
            .disabled(busyText != nil)
            .accessibilityIdentifier("export-backup")
        }
    }

    @ViewBuilder
    private var cacheSection: some View {
        Section("缓存") {
            SettingsLabel(
                "轨迹缓存",
                subtitle: trajectoryCacheSubtitle,
                value: ByteCountFormatter.string(
                    fromByteCount: trajectoryCacheSnapshot.bytes,
                    countStyle: .file))

            Button {
                showClearTrajectoryCacheConfirm = true
            } label: {
                SettingsLabel(
                    "清理轨迹缓存",
                    subtitle: "只清理可重新生成的地图轨迹数据",
                    showsChevron: true)
            }
            .disabled(trajectoryCacheSnapshot.bytes == 0)
            .accessibilityIdentifier("clear-trajectory-cache")
        }
    }

    private var trajectoryCacheSubtitle: LocalizedStringKey {
        switch trajectoryCacheSnapshot.budgetState {
        case .normal:
            return "用于加快地图和轨迹加载"
        case .aboveSoftBudget:
            return "已超过 96 MB 软预算，可安全清理"
        case .aboveHardBudget:
            return "已超过 128 MB 硬预算，可安全清理"
        }
    }

    @ViewBuilder
    private var generalSection: some View {
        Section("通用") {
            NavigationLink {
                AppearanceSettingsView(themeRaw: $themeRaw)
            } label: {
                SettingsLabel("外观", value: theme.name)
            }
            NavigationLink {
                LanguageSettingsView(appLanguageRaw: $appLanguageRaw)
            } label: {
                SettingsLabel("语言", value: language.nativeName)
            }
        }
    }

    @ViewBuilder
    private var dataManagementSection: some View {
        Section("数据管理") {
            Button("清除所有本地数据", role: .destructive) {
                showClearConfirm = true
            }
            .accessibilityIdentifier("reset-all-local-data")
        }
    }

    // MARK: - Operation UI

    @ViewBuilder
    private var operationOverlay: some View {
        if let busyText {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                VStack(spacing: 12) {
                    if let scanProgress {
                        ProgressView(value: scanProgress)
                            .frame(width: 150)
                        Text("\(Int(scanProgress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                    Text(busyText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    // MARK: - Actions

    private func rescan() {
        guard busyText == nil, let token = LocalImportCoordinator.shared.capture() else { return }
        busyText = "正在扫描相册…"
        scanProgress = 0
        let container = context.container
        Task.detached(priority: .userInitiated) {
            let status = await PhotoScanner.requestAccess()
            guard status == .authorized || status == .limited else {
                await MainActor.run {
                    guard LocalImportCoordinator.shared.isCurrent(token) else { return }
                    busyText = nil
                    scanProgress = nil
                    resultAlert = SettingsResultAlert(
                        title: "无法扫描相册", message: "请在系统设置中允许 Trace 访问照片。")
                }
                return
            }
            let result = PhotoScanner.scanWithPhotos(shouldContinue: {
                LocalImportCoordinator.shared.isCurrent(token)
            }) { done, total in
                guard total > 0 else { return }
                Task { @MainActor in
                    guard LocalImportCoordinator.shared.isCurrent(token) else { return }
                    scanProgress = min(1, Double(done) / Double(total))
                }
            }
            let saved = await PhotoStore.importPhotos(result.photoInfos, container: container, token: token)
            await MainActor.run {
                guard LocalImportCoordinator.shared.isCurrent(token) else { return }
                busyText = nil
                scanProgress = nil
                resultAlert = SettingsResultAlert(
                    title: ImportFeedback.title(saved), message: ImportFeedback.summary(saved))
            }
            Task { @MainActor in
                guard LocalImportCoordinator.shared.isCurrent(token), saved.status == .completed else { return }
                await PhotoThumbnailGenerator.generateForPending(
                    in: context, progress: { _, _ in })
                for _ in 0..<2 {
                    guard LocalImportCoordinator.shared.isCurrent(token) else { break }
                    if await RegionService.geocodeNextBatch(in: context) == 0 { break }
                }
            }
        }
    }

    /// 开启自动同步时沿用既有授权与首次同步流程；关闭时停掉 HealthKit observer。
    private func updateHealthAutomaticSync(_ enabled: Bool) {
        healthAutomaticSync = enabled
        if enabled {
            importHealthForAutomaticSync()
        } else {
            Task { await HealthKitSyncCoordinator.shared.disableAutomaticSync() }
        }
    }

    private func importHealthForAutomaticSync() {
        guard HealthKitService.isAvailable else {
            healthAutomaticSync = false
            return
        }
        busyText = "正在请求健康权限…"
        let container = context.container
        Task.detached(priority: .userInitiated) {
            _ = await HealthKitService.requestAndImport(
                container: container, enableAutomaticSync: true) { text in
                    Task { @MainActor in busyText = text }
                }
            await MainActor.run { busyText = nil }
        }
    }

    private func exportCSV() {
        do {
            exportDocument = ExportDocument(
                url: try FootprintStore.exportCSV(SnapshotCache.pointSnapshots))
        } catch {
            resultAlert = SettingsResultAlert(
                title: "导出失败", message: error.localizedDescription)
        }
    }

    private func refreshTrajectoryCacheSnapshot() {
        trajectoryCacheSnapshot = PersistentTrajectoryCache.shared.diskSnapshot(
            additionalDerivedBytes: PersistentRouteLODCache.shared.diskBytes())
    }

    private func clearTrajectoryCache() {
        PersistentTrajectoryCache.shared.clear()
        MapDisplaySnapshotStore.shared.clear()
        StatsSnapshotStore.shared.clear()
        PhotoTrajectoryAssociationStore.shared.clear()
        PersistentRouteLODCache.shared.clear()
        TrajectoryResolutionCache.shared.invalidate()
        refreshTrajectoryCacheSnapshot()
        resultAlert = SettingsResultAlert(
            title: "轨迹缓存已清理",
            message: "足迹、照片和运动记录均未删除。")
    }

    private func resetAllLocalData() {
        busyText = "正在清除本地数据…"
        scanProgress = nil
        Task {
            do {
                try await DataManagementService.resetAllLocalData(in: context)
                customMapSources = []
                busyText = nil
                resultAlert = SettingsResultAlert(
                    title: "已清除", message: "Trace 保存在本机的数据已清除。")
            } catch {
                busyText = nil
                resultAlert = SettingsResultAlert(
                    title: "清除失败", message: error.localizedDescription)
            }
        }
    }

    private func chooseImportFile() {
        guard busyText == nil else { return }
        #if DEBUG && targetEnvironment(simulator)
        let env = ProcessInfo.processInfo.environment
        if env["FP_UI_TEST"] == "1", env["FP_ISOLATED_REVIEW_STORE"] == "1",
           let scenario = env["FP_CSV_MAPPING_TEST"],
           let token = LocalImportCoordinator.shared.capture() {
            let csv = scenario == "missing-time"
                ? "latitude,longitude\n31,121\n31.001,121.001\n"
                : "latitude,longitude,time\n31,121,2026-09-11 08:00:00\n31,121,2026-09-11 08:00:01\n31,121,bad-date\n31,121,2026-09-11 08:00:00\n"
            csvImport = CSVImportPresentation(result: CSVParser.parse(csv), token: token)
            return
        }
        #endif
        showImporter = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard busyText == nil, case .success(let urls) = result, let url = urls.first,
              let token = LocalImportCoordinator.shared.capture() else { return }
        busyText = "正在解析文件…"
        Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                await MainActor.run {
                    guard LocalImportCoordinator.shared.isCurrent(token) else { return }
                    busyText = nil
                    resultAlert = SettingsResultAlert(
                        title: "导入失败", message: "无法读取所选文件。")
                }
                return
            }
            let parsed = CSVParser.parse(text)
            await MainActor.run {
                guard LocalImportCoordinator.shared.isCurrent(token) else { return }
                busyText = nil
                guard parsed.error == nil, !parsed.rows.isEmpty else {
                    resultAlert = SettingsResultAlert(
                        title: ImportFeedback.text("Import incomplete"),
                        message: ImportFeedback.text("No valid CSV rows. Check the file and quoted fields."))
                    return
                }
                // Always preview the time mapping before any persistent mutation.
                csvImport = CSVImportPresentation(result: parsed, token: token)
            }
        }
    }
}

private struct SettingsLabel: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let value: String?
    let showsChevron: Bool

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil,
         value: String? = nil, showsChevron: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.showsChevron = showsChevron
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct AppearanceSettingsView: View {
    @Binding var themeRaw: String

    var body: some View {
        Form {
            Section("足迹主题") {
                ForEach(AppTheme.allCases) { theme in
                    Button { themeRaw = theme.rawValue } label: {
                        HStack(spacing: 12) {
                            Circle().fill(theme.color).frame(width: 24, height: 24)
                            Text(theme.name).foregroundStyle(.primary)
                            Spacer()
                            if theme.rawValue == themeRaw {
                                Image(systemName: "checkmark").foregroundStyle(theme.color)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LanguageSettingsView: View {
    @Binding var appLanguageRaw: String

    var body: some View {
        Form {
            Section("语言") {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        appLanguageRaw = language.rawValue
                        AppLanguage.syncAppleLanguages(language.rawValue)
                    } label: {
                        HStack {
                            Text(language.nativeName).foregroundStyle(.primary)
                            Spacer()
                            if language.rawValue == appLanguageRaw {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("语言")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsResultAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct CSVImportPresentation: Identifiable {
    let id = UUID()
    let result: CSVParseResult
    let token: LocalImportCoordinator.Token
}

private struct ExportDocument: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
