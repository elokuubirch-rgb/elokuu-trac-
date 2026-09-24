import SwiftUI
import SwiftData

/// CSV 导入页：列映射（常见表头自动识别）+ 预览 + 后台导入（支持十万级数据）
struct CSVImportView: View {
    let result: CSVParseResult
    let importToken: LocalImportCoordinator.Token
    let onImported: (LocalImportResult, Int) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var mapping = ColumnMapping()
    @State private var importing = false
    @State private var outcome: LocalImportResult?
    @State private var issues: [CSVMappingResult.Issue] = []
    @State private var validationFailed = false
    @State private var diagnosingCoordinateSystem = false
    @State private var coordinateDiagnosis: CoordinateSystemDiagnosis?

    private var columns: [String] {
        if !result.header.isEmpty { return result.header }
        let count = result.rows.first?.count ?? 0
        return (0..<count).map { ImportFeedback.text("Column %lld", $0 + 1) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Required columns: latitude, longitude, time") {
                    mappingPicker("纬度", $mapping.latIndex)
                    mappingPicker("经度", $mapping.lonIndex)
                    mappingPicker("时间", $mapping.timeIndex)
                    mappingPicker("地点名", $mapping.nameIndex)
                }
                .disabled(importing || outcome?.status == .completed)
                coordinateSourceSection
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
                if let outcome {
                    Section {
                        Text(validationFailed
                             ? ImportFeedback.text("No valid measured points. Check the column mapping and invalid rows.")
                             : ImportFeedback.summary(outcome, skipped: issues.count))
                            .accessibilityIdentifier("csv-import-summary")
                        ForEach(Array(issues.prefix(20).enumerated()), id: \.offset) { _, issue in
                            Text(ImportFeedback.text("Data row %lld: %@", issue.row,
                                 ImportFeedback.text(issue.reason == .invalidCoordinate
                                     ? "Invalid coordinate" : "Missing or invalid time")))
                                .font(.caption)
                        }
                        if issues.count > 20 { Text("Showing the first 20 invalid rows.") }
                    } header: { Text(ImportFeedback.title(outcome)) }
                }
                Section {
                    Button(action: primaryAction) {
                        HStack {
                            Spacer()
                            if importing {
                                ProgressView().padding(.trailing, 6)
                                Text("正在导入 \(result.rows.count) 行…")
                            } else {
                                Text(LocalizedStringKey(outcome?.status == .completed ? "Done" : "导入"))
                            }
                            Spacer()
                        }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("csv-import-submit")
                    .disabled(mapping.latIndex == nil || mapping.lonIndex == nil
                              || mapping.timeIndex == nil || importing
                              || outcome?.status == .cancelled || result.rows.isEmpty)
                } footer: {
                    if mapping.latIndex == nil || mapping.lonIndex == nil || mapping.timeIndex == nil {
                        Text("Choose latitude, longitude and time columns. Missing dates will not be replaced with today.")
                    } else {
                        Text("Keep measured times and coordinates, including revisits. Skip only identical measurements. Dates without a time zone use this device’s time zone.")
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
        .interactiveDismissDisabled(importing)
        .preferredColorScheme(.dark)
        .onAppear {
            if mapping.latIndex == nil {
                mapping = CSVParser.smartMapping(result)
            }
        }
        .onChange(of: mapping.latIndex) { _, _ in coordinateDiagnosis = nil }
        .onChange(of: mapping.lonIndex) { _, _ in coordinateDiagnosis = nil }
        .onChange(of: mapping.timeIndex) { _, _ in coordinateDiagnosis = nil }
    }

    private func primaryAction() {
        if let outcome, outcome.status == .completed {
            onImported(outcome, issues.count)
            dismiss()
        } else { importNow() }
    }

    private func mappingPicker(_ title: String, _ index: Binding<Int?>) -> some View {
        Picker(LocalizedStringKey(title), selection: index) {
            Text("不使用").tag(Optional<Int>.none)
            ForEach(columns.indices, id: \.self) { i in
                Text(columns[i]).tag(Optional<Int>.some(i))
            }
        }
        .accessibilityIdentifier("csv-column-\(title)")
    }

    private var coordinateSourceSection: some View {
        Section {
            Picker("Coordinate system", selection: $mapping.sourceCoordinateSystem) {
                ForEach(CoordinateReferenceSystem.allCases, id: \.rawValue) { system in
                    coordinateSystemOption(system)
                }
            }
            .accessibilityIdentifier("csv-coordinate-system")

            Button(action: diagnoseCoordinateSource) {
                coordinateDiagnosisButtonLabel
            }
            .disabled(coordinateDiagnosisDisabled)

            if let diagnosis = coordinateDiagnosis {
                coordinateDiagnosisView(diagnosis)
            }
        } header: {
            Text("Coordinate source")
        } footer: {
            Text(ImportFeedback.text("Choose the system declared by the export source. Unknown keeps values unchanged. Analysis only suggests a choice and never edits data."))
        }
        .disabled(outcome?.status == .completed)
    }

    private var coordinateDiagnosisButtonLabel: some View {
        HStack(spacing: 8) {
            if diagnosingCoordinateSystem { ProgressView() }
            Image(systemName: "scope")
            Text(verbatim: diagnosingCoordinateSystem
                 ? ImportFeedback.text("Analyzing coordinate source…")
                 : ImportFeedback.text("Analyze coordinate source"))
        }
    }

    private var coordinateDiagnosisDisabled: Bool {
        diagnosingCoordinateSystem || importing || mapping.latIndex == nil
            || mapping.lonIndex == nil || mapping.timeIndex == nil
    }

    private func coordinateDiagnosisView(_ diagnosis: CoordinateSystemDiagnosis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: diagnosisSummary(diagnosis))
                .font(.subheadline)
            if let recommendation = diagnosis.recommendation,
               recommendation != mapping.sourceCoordinateSystem {
                Button(ImportFeedback.text("Use suggestion")) {
                    mapping.sourceCoordinateSystem = recommendation
                }
                .accessibilityIdentifier("csv-use-coordinate-suggestion")
            }
            Text(verbatim: diagnosisDetails(diagnosis))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 后台导入：mapPoints（纯计算）+ 入库（后台 ModelContext）全部离开主线程
    private func importNow() {
        guard !importing, let lat = mapping.latIndex, let lon = mapping.lonIndex,
              mapping.timeIndex != nil else { return }
        guard LocalImportCoordinator.shared.isCurrent(importToken) else {
            outcome = LocalImportResult(status: .cancelled)
            return
        }
        importing = true
        validationFailed = false
        let parsed = result
        let container = context.container
        let selectedMapping = ColumnMapping(latIndex: lat, lonIndex: lon,
                                            timeIndex: mapping.timeIndex,
                                            nameIndex: mapping.nameIndex,
                                            sourceCoordinateSystem: mapping.sourceCoordinateSystem)
        Task.detached(priority: .userInitiated) {
            let mapped = parsed.validatedPoints(selectedMapping)
            let noValidPoints = mapped.points.isEmpty && !mapped.issues.isEmpty
            let saved = noValidPoints ? LocalImportResult(status: .failed)
                : await FootprintStore.importMeasurements(
                    mapped.points, container: container, token: importToken)
            await MainActor.run {
                importing = false
                issues = mapped.issues
                validationFailed = noValidPoints
                outcome = LocalImportCoordinator.shared.isCurrent(importToken)
                    ? saved : LocalImportResult(status: .cancelled)
            }
        }
    }

    private func diagnoseCoordinateSource() {
        guard !diagnosingCoordinateSystem else { return }
        let candidates = result.coordinateObservations(mapping)
        guard let first = candidates.map(\.timestamp).min(),
              let last = candidates.map(\.timestamp).max(), !candidates.isEmpty else {
            coordinateDiagnosis = CoordinateSystemDiagnosis(
                recommendation: nil, matchedSampleCount: 0, scores: [])
            return
        }
        diagnosingCoordinateSystem = true
        coordinateDiagnosis = nil
        let container = context.container
        Task {
            let diagnosis = await Task.detached(priority: .userInitiated) {
                let lowerBound = first.addingTimeInterval(-30 * 60)
                let upperBound = last.addingTimeInterval(30 * 60)
                let background = ModelContext(container)
                background.autosaveEnabled = false
                let predicate = #Predicate<PhotoRecord> {
                    $0.timestamp >= lowerBound && $0.timestamp <= upperBound
                }
                var descriptor = FetchDescriptor<PhotoRecord>(
                    predicate: predicate, sortBy: [SortDescriptor(\.timestamp)])
                descriptor.fetchLimit = 8_000
                let references = (try? background.fetch(descriptor))?.map {
                    TimedCoordinateObservation(latitude: $0.latitude, longitude: $0.longitude,
                                               timestamp: $0.timestamp)
                } ?? []
                return CoordinateSystemDiagnoser.diagnose(
                    candidates: candidates, references: references)
            }.value
            diagnosingCoordinateSystem = false
            coordinateDiagnosis = diagnosis
        }
    }

    private func coordinateSystemName(_ system: CoordinateReferenceSystem) -> String {
        switch system {
        case .unknown: return ImportFeedback.text("Unknown — keep original values")
        case .wgs84: return ImportFeedback.text("WGS-84 — GPS / international")
        case .gcj02: return ImportFeedback.text("GCJ-02 — Amap / Tencent")
        }
    }

    private func coordinateSystemOption(_ system: CoordinateReferenceSystem) -> some View {
        Text(verbatim: coordinateSystemName(system)).tag(system)
    }

    private func diagnosisSummary(_ diagnosis: CoordinateSystemDiagnosis) -> String {
        if let recommendation = diagnosis.recommendation {
            return ImportFeedback.text("Suggestion: %@ · %lld matched samples",
                                       coordinateSystemName(recommendation),
                                       diagnosis.matchedSampleCount)
        }
        return ImportFeedback.text("Unable to determine · %lld matched samples",
                                   diagnosis.matchedSampleCount)
    }

    private func diagnosisDetails(_ diagnosis: CoordinateSystemDiagnosis) -> String {
        guard !diagnosis.scores.isEmpty else {
            return ImportFeedback.text("At least 5 time-matched photo samples are required.")
        }
        return diagnosis.scores.map {
            ImportFeedback.text("%@: median %lld m", coordinateSystemName($0.system),
                                Int($0.medianDistanceMeters.rounded()))
        }.joined(separator: " · ")
    }
}
