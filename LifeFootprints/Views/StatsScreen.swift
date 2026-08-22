import SwiftUI

/// 统计页：总览卡片 + 每年足迹 + 足迹最密集的区域
struct StatsScreen: View {
    /// 常驻架构：统计页始终挂载；isActive 决定是否允许后台重算密集区域聚类。
    let isActive: Bool

    @AppStorage("theme") private var themeRaw = AppTheme.crimson.rawValue
    @State private var snapshots: [FootprintSnapshot] = []
    @State private var cachedStats = FootprintStats()
    /// 密集区域聚类：后台重算后缓存，body 零重活（P0）。
    @State private var cachedClusters: [(lat: Double, lon: Double, count: Int)] = []
    @State private var clustersGeneration = 0

    private var theme: AppTheme { AppTheme(rawValue: themeRaw) ?? .crimson }
    private var stats: FootprintStats { cachedStats }
    private var clusters: [(lat: Double, lon: Double, count: Int)] { cachedClusters }

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    var body: some View {
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
        }
        .preferredColorScheme(.dark)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .onAppear {
            #if DEBUG
            MapDebugLog.log("StatsScreen onAppear（挂载）")
            #endif
            refreshCache()
        }
        .onChange(of: isActive) { _, active in
            if active { scheduleClustersRebuild() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mapSnapshotReady)) { _ in
            refreshCache()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dataImported)) { _ in
            refreshCache()
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

    /// 134k 点的聚类在后台线程重算；统计页不可见时直接跳过。
    private func scheduleClustersRebuild() {
        guard isActive else { return }
        clustersGeneration += 1
        let generation = clustersGeneration
        let source = snapshots
        Task.detached(priority: .utility) {
            let pts = source.map { (lat: $0.lat, lon: $0.lon) }
            let result = GeoMath.topClusters(pts, topN: 5)
            await MainActor.run {
                guard generation == self.clustersGeneration else { return }
                self.cachedClusters = result
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
