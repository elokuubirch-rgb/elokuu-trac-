import SwiftUI

/// 统计页：总览卡片 + 每年足迹 + 足迹最密集的区域
struct StatsScreen: View {
    /// 常驻架构：统计页始终挂载；isActive 决定是否允许后台重算密集区域聚类。
    let isActive: Bool

    @AppStorage("theme") private var themeRaw = AppTheme.crimson.rawValue
    @State private var snapshots: [FootprintSnapshot] = []
    @State private var cachedStats = FootprintStats()
    /// 密集区域聚类：后台重算后缓存，body 零重活（P0）。
    @State private var cachedClusters: [StatsDenseArea] = []
    @State private var clustersGeneration = 0
    @State private var appliedClusterKey: StatsClusterCacheKey?
    @State private var clusterConsumerTask: Task<Void, Never>?
    #if DEBUG
    @State private var diagnosticSettingsPresented = false
    #endif

    private var theme: AppTheme { AppTheme(rawValue: themeRaw) ?? .crimson }
    private var stats: FootprintStats { cachedStats }
    private var clusters: [StatsDenseArea] { cachedClusters }

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    var body: some View {
        #if DEBUG
        let _ = PerformanceDiagnostics.event("StatsScreen.body")
        #endif
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        statCard("足迹点", "\(stats.pointCount)")
                        statCard("总里程", String(format: "%.0f KM", stats.distanceKM))
                        statCard("活跃天", "\(stats.activeDays)")
                    }
                    yearlyCard
                    clustersCard
                    if let first = stats.firstDate, let last = stats.lastDate {
                        HStack {
                            Text("时间跨度")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(first.formatted(date: .abbreviated, time: .omitted)) — \(last.formatted(date: .abbreviated, time: .omitted))")
                                .font(.subheadline)
                        }
                        .cardStyle()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle("统计")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsScreen()
                    } label: {
                        Image(systemName: "gearshape")
                            .accessibilityLabel("设置")
                    }
                }
            }
            #if DEBUG
            .navigationDestination(isPresented: $diagnosticSettingsPresented) {
                SettingsScreen()
            }
            #endif
        }
        .preferredColorScheme(.dark)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .onAppear {
            #if DEBUG
            PerformanceDiagnostics.event("StatsScreen.onAppear")
            MapDebugLog.log("StatsScreen onAppear（挂载）")
            #endif
            refreshCache()
        }
        .onChange(of: isActive) { _, active in
            #if DEBUG
            PerformanceDiagnostics.event("StatsScreen.isActiveChanged",
                                           metadata: active ? "active" : "inactive")
            #endif
            if active { scheduleClustersRebuild() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mapSnapshotReady)) { _ in
            refreshCache()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dataRevisionChanged)) { notification in
            guard let change = notification.object as? DataRevisionChange,
                  !change.domains.intersection([.place, .trajectory]).isEmpty else { return }
            #if DEBUG
            PerformanceDiagnostics.event("dataRevision.receive.StatsScreen")
            #endif
            refreshCache()
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .performanceOpenSettings)) { _ in
            guard PerformanceDiagnostics.isEnabled else { return }
            PerformanceDiagnostics.beginTransition("Stats->Settings")
            diagnosticSettingsPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .performanceCloseSettings)) { _ in
            guard PerformanceDiagnostics.isEnabled else { return }
            PerformanceDiagnostics.beginTransition("Settings->Stats")
            diagnosticSettingsPresented = false
        }
        #endif
        .onDisappear {
            #if DEBUG
            PerformanceDiagnostics.event("StatsScreen.onDisappear")
            #endif
        }
    }

    private func statCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .heavy))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }

    private var yearlyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("每年足迹").font(.headline)
            if stats.perYear.isEmpty {
                Text("暂无数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                let maxCount = stats.perYear.map(\.count).max() ?? 1
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(stats.perYear, id: \.year) { item in
                        VStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(barColor(year: item.year))
                                .frame(height: CGFloat(item.count) / CGFloat(maxCount) * 90 + 4)
                            Text(String(item.year % 100))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 112)
            }
        }
        .cardStyle()
    }

    private func barColor(year: Int) -> Color {
        year >= currentYear - 1 ? theme.color : Color.white.opacity(0.15)
    }

    private func refreshCache() {
        snapshots = SnapshotCache.pointSnapshots
        cachedStats = SnapshotCache.stats
        scheduleClustersRebuild()
    }

    /// 聚类结果按持久数据 revision 复用；并发 consumer 共用同一个后台 task。
    private func scheduleClustersRebuild() {
        guard isActive else { return }
        let revision = DataRevisionStore.snapshot()
        let key = StatsClusterCacheKey(
            placeRevision: revision.place,
            trajectoryRevision: revision.trajectory,
            snapshotGeneration: SnapshotCache.pointSnapshotGeneration)
        guard appliedClusterKey != key else {
            #if DEBUG
            PerformanceDiagnostics.count("StatsCluster.screenReuse")
            #endif
            return
        }
        #if DEBUG
        PerformanceDiagnostics.count("StatsCluster.consumer.started")
        #endif
        clustersGeneration += 1
        let generation = clustersGeneration
        let source = snapshots
        clusterConsumerTask?.cancel()
        clusterConsumerTask = Task {
            let result = await StatsClusterRevisionCache.shared.value(
                for: key, snapshots: source)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard generation == self.clustersGeneration else { return }
                self.cachedClusters = result
                self.appliedClusterKey = key
            }
        }
    }

    private var clustersCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("足迹最密集的区域").font(.headline)
            if clusters.isEmpty {
                Text("暂无数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(clusters.enumerated()), id: \.offset) { index, cluster in
                    HStack {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(String(format: "%.3f°, %.3f°", cluster.lat, cluster.lon))
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("\(cluster.count) 个点")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    if index < clusters.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .cardStyle()
    }
}
