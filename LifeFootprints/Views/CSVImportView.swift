import SwiftUI
import SwiftData

/// CSV 导入页：列映射（常见表头自动识别）+ 预览 + 后台导入（支持十万级数据）
struct CSVImportView: View {
    let result: CSVParseResult
    let onImported: (Int, Int) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var mapping = ColumnMapping()
    @State private var importing = false

    private var columns: [String] {
        if !result.header.isEmpty { return result.header }
        let count = result.rows.first?.count ?? 0
        return (0..<count).map { "第 \($0 + 1) 列" }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("列映射（必填：纬度、经度）") {
                    mappingPicker("纬度", $mapping.latIndex)
                    mappingPicker("经度", $mapping.lonIndex)
                    mappingPicker("时间", $mapping.timeIndex)
                    mappingPicker("地点名", $mapping.nameIndex)
                }
                Section("数据预览（前 5 行 · 共 \(result.rows.count) 行）") {
                    if result.rows.isEmpty {
                        Text("没有可解析的数据行").foregroundStyle(.secondary)
                    } else {
                        ForEach(result.rows.prefix(5).indices, id: \.self) { index in
                            Text(result.rows[index].joined(separator: " · "))
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
                Section {
                    Button(action: importNow) {
                        HStack {
                            Spacer()
                            if importing {
                                ProgressView().padding(.trailing, 6)
                                Text("正在导入 \(result.rows.count) 行…")
                            } else {
                                Text("导入")
                            }
                            Spacer()
                        }
                    }
                    .disabled(mapping.latIndex == nil || mapping.lonIndex == nil || importing)
                } footer: {
                    if mapping.latIndex == nil || mapping.lonIndex == nil {
                        Text("请先在「列映射」中选择纬度和经度对应的列，导入按钮才会启用。")
                    } else {
                        Text("导入在后台线程执行（十万级数据不卡界面），并按「同一天 ±50 米」自动去重。")
                    }
                }
            }
            .navigationTitle("导入 CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(importing)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if mapping.latIndex == nil {
                mapping = CSVParser.smartMapping(result)
            }
        }
    }

    private func mappingPicker(_ title: String, _ index: Binding<Int?>) -> some View {
        Picker(title, selection: index) {
            Text("不使用").tag(Optional<Int>.none)
            ForEach(columns.indices, id: \.self) { i in
                Text(columns[i]).tag(Optional<Int>.some(i))
            }
        }
    }

    /// 后台导入：mapPoints（纯计算）+ 入库（后台 ModelContext）全部离开主线程
    private func importNow() {
        guard let lat = mapping.latIndex, let lon = mapping.lonIndex else { return }
        importing = true
        let parsed = result
        let container = context.container
        let selectedMapping = ColumnMapping(latIndex: lat, lonIndex: lon,
                                            timeIndex: mapping.timeIndex,
                                            nameIndex: mapping.nameIndex)
        Task.detached(priority: .userInitiated) {
            let mapped = parsed.mapPoints(selectedMapping)
            let added = await FootprintStore.importDraftsInBackground(mapped.points, container: container)
            let skipped = mapped.skipped
            await MainActor.run {
                onImported(added, skipped)
                dismiss()
            }
        }
    }
}
