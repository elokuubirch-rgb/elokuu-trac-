import SwiftUI

/// 类似文件夹的自定义地图源管理页：导入、多选、批量删除。
struct MapSourceManagementView: View {
    @AppStorage("mapType") private var mapTypeRaw = "standard"
    @State private var sources: [CustomMapSource] = []
    @State private var selectedIDs: Set<UUID> = []
    @State private var isSelecting = false
    @State private var showEditor = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        List {
            if sources.isEmpty {
                ContentUnavailableView(
                    "暂无自定义地图源",
                    systemImage: "folder",
                    description: Text("点击右上角 + 导入 XYZ/TMS 地图源"))
                .listRowBackground(Color.clear)
            } else {
                ForEach(sources) { source in
                    Button {
                        guard isSelecting else { return }
                        if selectedIDs.contains(source.id) {
                            selectedIDs.remove(source.id)
                        } else {
                            selectedIDs.insert(source.id)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if isSelecting {
                                Image(systemName: selectedIDs.contains(source.id) ?
                                      "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIDs.contains(source.id) ? .red : .secondary)
                                    .font(.system(size: 20))
                            }
                            Image(systemName: "square.stack.3d.up.fill")
                                .foregroundStyle(.green)
                                .frame(width: 30, height: 30)
                                .background(Color.green.opacity(0.14),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text("\(source.scheme.rawValue.uppercased()) · \(source.minimumZoom)–\(source.maximumZoom)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(source.attribution)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        if !isSelecting {
                            Button("删除", role: .destructive) {
                                delete(ids: [source.id])
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("自定义地图源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !sources.isEmpty {
                    Button(isSelecting ? "完成" : "选择") {
                        isSelecting.toggle()
                        if !isSelecting { selectedIDs.removeAll() }
                    }
                }
                if !isSelecting {
                    Button { showEditor = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("导入地图源")
                }
            }
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedIDs.count == sources.count ? "取消全选" : "全选") {
                        selectedIDs = selectedIDs.count == sources.count ? [] : Set(sources.map(\.id))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label(selectedIDs.isEmpty ? "删除" : "删除所选（\(selectedIDs.count)）",
                          systemImage: "trash.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedIDs.isEmpty)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
        }
        .confirmationDialog("删除所选地图源？", isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("删除 \(selectedIDs.count) 个地图源", role: .destructive) {
                delete(ids: selectedIDs)
                selectedIDs.removeAll()
                isSelecting = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后需要重新导入才能恢复。")
        }
        .sheet(isPresented: $showEditor) {
            MapSourceEditorView()
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .mapSourcesChanged)) { _ in
            reload()
        }
    }

    private func reload() {
        sources = MapSourceStore.load()
        selectedIDs.formIntersection(Set(sources.map(\.id)))
    }

    private func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if mapTypeRaw.hasPrefix("custom:"),
           let activeID = UUID(uuidString: String(mapTypeRaw.dropFirst("custom:".count))),
           ids.contains(activeID) {
            mapTypeRaw = "standard"
        }
        MapSourceStore.remove(ids: ids)
    }
}
