import SwiftUI
import Photos

/// 首次启动：授权相册 → 扫描照片位置 → 生成足迹地图
struct OnboardingView: View {
    let onDone: () -> Void
    @Environment(\.modelContext) private var context
    @State private var scanning = false
    @State private var scanText: String?
    @State private var doneCount: Int?
    @State private var showDeniedAlert = false

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(red: 0.09, green: 0.11, blue: 0.18), .black],
                           center: .top, startRadius: 0, endRadius: 460)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 70)
                logo
                Text("Tracé")
                    .font(.system(size: 28, weight: .heavy))
                    .tracking(4)
                    .padding(.top, 30)
                Text("这不是城市的地图\n这是你的地图")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .padding(.top, 10)
                Spacer()

                if let count = doneCount {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.green)
                        Text("已提取 \(count) 个足迹点")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(height: 92)
                } else if scanning {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(scanText ?? "正在扫描照片中的位置…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .frame(height: 92)
                } else {
                    Button(action: startScan) {
                        Text("授权访问相册")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color(red: 0.9, green: 0.23, blue: 0.32),
                                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    Button("之后再说 · 从 CSV 导入") { onDone() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.9, green: 0.23, blue: 0.32))
                        .padding(.top, 14)
                }

                Text("数据仅保存在本机 · 无上传 · 无广告")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 22)
                    .padding(.bottom, 34)
            }
            .padding(.horizontal, 28)
        }
        .preferredColorScheme(.dark)
        .alert("需要相册权限", isPresented: $showDeniedAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("请在 设置 → 隐私与安全性 → 照片 中允许「Tracé」访问相册，才能提取照片中的位置。")
        }
        .onAppear {
            #if DEBUG
            if TestHooks.autoScan, !scanning, doneCount == nil {
                startScan()
            }
            #endif
        }
    }

    private var logo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 1.0, green: 0.35, blue: 0.42), Color(red: 0.88, green: 0.16, blue: 0.27)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: 96, height: 96)
        .shadow(color: Color.red.opacity(0.4), radius: 22, y: 10)
    }

    private func startScan() {
        appLog.info("[Onboarding] startScan 开始（后台线程）")
        scanning = true
        scanText = nil
        let container = context.container
        // 大相册扫描必须离开主线程，否则 UI 冻结黑屏
        Task.detached(priority: .userInitiated) {
            let status = await PhotoScanner.requestAccess()
            await MainActor.run { appLog.info("[Onboarding] 相册权限状态: \(status.rawValue)") }
            guard status == .authorized || status == .limited else {
                await MainActor.run {
                    scanning = false
                    showDeniedAlert = true
                }
                return
            }
            // 重型 IO：全量照片元数据枚举（后台）
            let result = PhotoScanner.scanWithPhotos(progress: { done, total in
                Task { @MainActor in
                    scanText = "正在扫描 \(done) / \(total) 张照片"
                }
            })
            let drafts = result.drafts
            let infos = result.photoInfos
            // 入库（后台 ModelContext，主线程零阻塞）
            let added = await FootprintStore.importDraftsInBackground(drafts, container: container)
            let photoAdded = await PhotoStore.upsertInBackground(infos, container: container)
            await MainActor.run {
                appLog.info("[Onboarding] 足迹新增 \(added)，照片新增 \(photoAdded)")
                doneCount = added
                scanText = nil
            }
            // 后台收尾：缩略图 + 行政区逆地理（限两批；进入主界面后由 MainTabView 常驻循环接管）
            Task { @MainActor in
                await PhotoThumbnailGenerator.generateForPending(in: context, progress: { _, _ in })
                for _ in 0..<2 {
                    if await RegionService.geocodeNextBatch(in: context) == 0 { break }
                }
            }
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run { onDone() }
        }
    }
}
