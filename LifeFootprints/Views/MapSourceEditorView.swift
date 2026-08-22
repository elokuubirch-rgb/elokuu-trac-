import SwiftUI

struct MapSourceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlTemplate = ""
    @State private var scheme: MapTileScheme = .xyz
    @State private var minimumZoom = 0
    @State private var maximumZoom = 19
    @State private var attribution = ""
    @State private var validationMessage: String?
    @State private var inputNotice: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("地图源") {
                    TextField("名称", text: $name)
                    TextField("URL 或 iframe", text: $urlTemplate)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.caption, design: .monospaced))
                        .onChange(of: urlTemplate) { _, value in
                            recognizeInputIfNeeded(value)
                        }
                    if let inputNotice {
                        Label(inputNotice, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Picker("坐标方案", selection: $scheme) {
                        Text("XYZ").tag(MapTileScheme.xyz)
                        Text("TMS").tag(MapTileScheme.tms)
                    }
                    .pickerStyle(.segmented)
                }
                Section("缩放层级") {
                    Stepper("最小层级  \(minimumZoom)", value: $minimumZoom, in: 0...22)
                    Stepper("最大层级  \(maximumZoom)", value: $maximumZoom, in: 0...22)
                }
                Section {
                    TextField("例如：© OpenStreetMap contributors", text: $attribution)
                } header: {
                    Text("版权署名")
                } footer: {
                    Text("仅支持获得授权的 HTTPS XYZ/TMS 瓦片。Google 地图必须通过官方 Maps Platform 接入，不能粘贴非公开瓦片地址。")
                }
                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("导入地图源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入", action: save)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        let source = CustomMapSource(name: name, urlTemplate: urlTemplate,
                                     scheme: scheme, minimumZoom: minimumZoom,
                                     maximumZoom: maximumZoom, attribution: attribution)
        if let error = CustomMapSourceValidator.validationError(for: source) {
            validationMessage = error
            return
        }
        MapSourceStore.upsert(source)
        dismiss()
    }

    private func recognizeInputIfNeeded(_ value: String) {
        let isIframe = value.range(of: "<iframe", options: .caseInsensitive) != nil
        let isMapTilerPreview = value.contains("api.maptiler.com/maps/") && !value.contains("{z}")
        guard isIframe || isMapTilerPreview,
              let parsed = MapSourceInputParser.parse(value) else { return }
        urlTemplate = parsed.urlTemplate
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = parsed.suggestedName ?? name
        }
        if attribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            attribution = parsed.suggestedAttribution ?? attribution
        }
        if let zoom = parsed.suggestedMaximumZoom { maximumZoom = zoom }
        scheme = .xyz
        validationMessage = nil
        inputNotice = parsed.suggestedName == nil ? "已自动识别地图地址" : "已自动识别 MapTiler 地图"
    }
}
