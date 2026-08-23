import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 设置页：数据来源 / 操作 / 外观 / 隐私
struct SettingsScreen: View {
    @Environment(\.modelContext) private var context
    @AppStorage("theme") private var themeRaw = AppTheme.crimson.rawValue
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.simplifiedChinese.rawValue

    @State private var busyText: String?
    @State private var scanResult: Int?
    @State private var showImporter = false
    @State private var showCSVSheet = false
    @State private var csvResult: CSVParseResult?
    @State private var showClearConfirm = false
    @State private var exportURL: URL?
    @State private var customMapSources: [CustomMapSource] = []

    private var theme: AppTheme { AppTheme(rawValue: themeRaw) ?? .crimson }
    @State private var sourceCounts = (photo: 0, csv: 0, manual: 0, gps: 0, health: 0)
    @AppStorage("bgFootprints") private var bgFootprints = false
    @AppStorage("reviewRecentDedupEnabled") private var reviewRecentDedupEnabled = true
    @AppStorage("reviewGroupSize") private var reviewGroupSize = 20

    var body: some View {
        NavigationStack {
            List {
                Section("数据来源") {
                    sourceRow("photo", "照片位置", "自动提取 GPS 拍摄地", "\(sourceCounts.photo) 条", .blue)
                    sourceRow("doc.text", "CSV 文件", "一生足迹备份 / 手动导入", "\(sourceCounts.csv) 条", .cyan)
                    sourceRow("heart.circle.fill", "苹果健康", "Apple Watch 锻炼路线", "\(sourceCounts.health) 条", .pink)
                    sourceRow("location.fill", "轨迹记录", "主动录制 + 后台低功耗留痕", "\(sourceCounts.gps) 条", .red)
                    sourceRow("plus", "手动添加", "长按地图补充（待实现）", "\(sourceCounts.manual) 条", .green)
                }

                Section {
                    Toggle(isOn: $bgFootprints) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("后台足迹（低功耗）")
                            Text("路过常去地点自动留痕，持续生长足迹地图")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: bgFootprints) { _, on in
                        LocationService.shared.setBackgroundFootprints(on)
                    }
                } header: {
                    Text("定位")
                } footer: {
                    Text("基于系统「访问监测」和「重大位置变化」。日常停留自动留点；高铁、飞机按距离稀疏记录关键点，不持续开启 GPS。开启需允许「始终」访问位置。")
                }

                Section {
                    Toggle(isOn: $reviewRecentDedupEnabled) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("近期不重复回顾")
                            Text("30 天内真正看过的照片，优先让位给没看过的")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Stepper(value: $reviewGroupSize, in: 1...100) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("每组照片数量")
                            Text("下一轮回顾生效，当前三组不受影响")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(reviewGroupSize) 张")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("回顾")
                } footer: {
                    Text("只有真正在浏览中看过的照片才算“回顾过”。生成新一轮回顾时，按「没看过 → 很久没看 → 刚看过」排序；照片不足时用最久没看的自动补足，不会出现“没有更多”。")
                }

                Section {
                    sourceRow("map", "标准地图", "Apple MapKit", "内置", .blue)
                    sourceRow("globe.asia.australia", "卫星地图", "Apple 卫星影像", "内置", .indigo)
                    NavigationLink {
                        MapSourceManagementView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.green)
                                .frame(width: 30, height: 30)
                                .background(Color.green.opacity(0.14),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text("自定义地图源")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Text("\(customMapSources.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("地图源")
                } footer: {
                    Text("自定义地图源必须使用 HTTPS 并保留版权署名。Google 地图需通过官方 Maps Platform 接入。")
                }

                Section("操作") {
                    Button { rescan() } label: {
                        actionRow("arrow.clockwise", "重新扫描相册", "同步新增照片的位置")
                    }
                    Button { showImporter = true } label: {
                        actionRow("doc.badge.plus", "导入 CSV 文件", "自动识别列 · 一生足迹备份直接导入")
                    }
                    Button { importHealth() } label: {
                        actionRow("figure.run", "导入苹果健康运动", "Apple Watch / iPhone 锻炼路线")
                    }
                    Button { exportCSV() } label: {
                        actionRow("square.and.arrow.up", "导出备份", "生成 CSV 文件")
                    }
                    if let url = exportURL {
                        ShareLink(item: url, preview: SharePreview("足迹备份.csv")) {
                            actionRow("checkmark.circle.fill", "分享导出的备份", url.lastPathComponent)
                        }
                    }
                }

                Section("外观") {
                    HStack(spacing: 14) {
                        ForEach(AppTheme.allCases) { t in
                            Button { themeRaw = t.rawValue } label: {
                                Circle().fill(t.color)
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(
                                        t == theme ? Color.white : Color.white.opacity(0.2),
                                        lineWidth: t == theme ? 2.5 : 1))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        Text(theme.name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("语言") {
                    Picker("应用语言", selection: $appLanguageRaw) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.nativeName).tag(language.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: appLanguageRaw) { _, newValue in
                        // 立即同步系统级回退，避免语言切换后旧值仍被回退路径使用。
                        AppLanguage.syncAppleLanguages(newValue)
                    }
                }

                Section {
                    HStack {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(.green)
                        Text("数据仅保存在本机")
                        Spacer()
                        Text("无账号 · 无上传 · 无广告")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button(role: .destructive) { showClearConfirm = true } label: {
                        HStack {
                            Spacer()
                            Text("清空所有数据")
                            Spacer()
                        }
                    }
                }

                Section {
                    Text("版本 1.0.0 · Tracé")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("设置")
            .overlay {
                if let busy = busyText {
                    ZStack {
                        Color.black.opacity(0.5).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(busy)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
            .alert("扫描完成", isPresented: scanResultAlertBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(scanResult.map { "新增 \($0) 个足迹点" } ?? "")
            }
            .confirmationDialog("确定要清空所有数据吗？此操作不可恢复",
                                isPresented: $showClearConfirm,
                                titleVisibility: .visible) {
                Button("清空", role: .destructive) { FootprintStore.deleteAll(in: context) }
                Button("取消", role: .cancel) {}
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .data],
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .sheet(isPresented: $showCSVSheet) {
                if let result = csvResult {
                    CSVImportView(result: result) { added, _ in
                        scanResult = added
                        csvResult = nil
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: refreshSourceCounts)
        .onAppear { customMapSources = MapSourceStore.load() }
        .onReceive(NotificationCenter.default.publisher(for: .mapSnapshotReady)) { _ in
            refreshSourceCounts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dataImported)) { _ in
            refreshSourceCounts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mapSourcesChanged)) { _ in
            customMapSources = MapSourceStore.load()
        }
    }

    private var scanResultAlertBinding: Binding<Bool> {
        Binding(get: { scanResult != nil },
                set: { if !$0 { scanResult = nil } })
    }

    // MARK: - 行样式

    private func sourceRow(_ icon: String, _ title: String, _ subtitle: String,
                           _ value: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(title)).font(.system(size: 14, weight: .semibold))
                if !subtitle.isEmpty {
                    Text(LocalizedStringKey(subtitle)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(LocalizedStringKey(value))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private func actionRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(title)).font(.system(size: 14, weight: .semibold))
                if !subtitle.isEmpty {
                    Text(LocalizedStringKey(subtitle)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 动作

    private func rescan() {
        busyText = "正在扫描相册…"
        let container = context.container
        Task.detached(priority: .userInitiated) {
            let status = await PhotoScanner.requestAccess()
            guard status == .authorized || status == .limited else {
                await MainActor.run { busyText = nil }
                return
            }
            let result = PhotoScanner.scanWithPhotos(progress: { _, _ in })
            let added = await PhotoStore.upsertInBackground(result.photoInfos, container: container)
            await MainActor.run {
                busyText = nil
                scanResult = added
            }
            Task { @MainActor in
                await PhotoThumbnailGenerator.generateForPending(in: context, progress: { _, _ in })
                for _ in 0..<2 {
                    if await RegionService.geocodeNextBatch(in: context) == 0 { break }
                }
            }
        }
    }

    /// 苹果健康：授权 → 读取全部锻炼路线 → 后台融合入库
    private func importHealth() {
        guard HealthKitService.isAvailable else {
            scanResult = 0
            return
        }
        busyText = "正在请求健康权限…"
        let container = context.container
        Task.detached(priority: .userInitiated) {
            let added = await HealthKitService.requestAndImport(container: container) { text in
                Task { @MainActor in busyText = text }
            }
            await MainActor.run {
                busyText = nil
                scanResult = added
            }
        }
    }

    private func exportCSV() {
        exportURL = try? FootprintStore.exportCSV(SnapshotCache.pointSnapshots)
    }

    private func refreshSourceCounts() {
        var result = (photo: 0, csv: 0, manual: 0, gps: 0, health: 0)
        for point in SnapshotCache.pointSnapshots {
            switch point.source {
            case FootprintSource.photo.rawValue: result.photo += 1
            case FootprintSource.csv.rawValue: result.csv += 1
            case FootprintSource.manual.rawValue: result.manual += 1
            case FootprintSource.gps.rawValue: result.gps += 1
            case FootprintSource.health.rawValue: result.health += 1
            default: break
            }
        }
        sourceCounts = result
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        busyText = "正在解析文件…"
        let container = context.container
        Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                await MainActor.run { busyText = nil }
                return
            }
            let parsed = CSVParser.parse(text)
            guard parsed.error == nil, !parsed.rows.isEmpty else {
                await MainActor.run { busyText = nil }
                return
            }
            // 智能映射：表头关键词 + 数据嗅探
            let mapping = CSVParser.smartMapping(parsed)
            if mapping.latIndex != nil, mapping.lonIndex != nil {
                // 自动识别成功 → 直接后台导入（选完文件即入库）
                let rows = parsed.rows.count
                await MainActor.run { busyText = "正在导入 \(rows) 行…" }
                let mapped = parsed.mapPoints(mapping)
                let added = await FootprintStore.importDraftsInBackground(mapped.points, container: container)
                await MainActor.run {
                    busyText = nil
                    scanResult = added
                }
            } else {
                // 无法识别 → 打开手动列映射页
                await MainActor.run {
                    busyText = nil
                    csvResult = parsed
                    showCSVSheet = true
                }
            }
        }
    }
}
