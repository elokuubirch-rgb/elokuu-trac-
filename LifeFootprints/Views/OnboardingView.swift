import SwiftUI
import Photos

/// 首次启动权限按固定顺序完成，避免多个系统授权弹窗相互覆盖。
struct OnboardingView: View {
    private enum PermissionStep: Int {
        case location
        case photos
        case health
        case completed
    }

    private enum PermissionResult {
        case pending
        case working
        case enabled(String)
        case off(String)
    }

    let onDone: () -> Void
    @Environment(\.modelContext) private var context
    @State private var locationService = LocationService.shared
    @State private var step: PermissionStep = .location
    @State private var locationResult: PermissionResult = .pending
    @State private var photoResult: PermissionResult = .pending
    @State private var healthResult: PermissionResult = .pending
    @State private var scanText: String?
    @State private var didFinish = false

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color(red: 0.09, green: 0.11, blue: 0.18), .black],
                center: .top, startRadius: 0, endRadius: 540)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    logo
                        .padding(.top, 46)
                    Text("Tracé")
                        .font(.system(size: 27, weight: .heavy))
                        .tracking(4)
                        .padding(.top, 20)
                    Text("把走过的地方、照片与真实轨迹\n连成属于你的生命地图")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                        .padding(.top, 8)

                    VStack(spacing: 12) {
                        permissionCard(
                            number: 1,
                            icon: "location.fill",
                            title: "后台位置",
                            detail: "持续记录重要的位置变化，让足迹保持连续",
                            result: locationResult,
                            isActive: step == .location,
                            primaryTitle: "开启后台位置",
                            primaryAction: enableBackgroundLocation,
                            secondaryTitle: "关闭",
                            secondaryAction: disableBackgroundLocation)

                        permissionCard(
                            number: 2,
                            icon: "photo.on.rectangle.angled",
                            title: "照片地点",
                            detail: scanText ?? "读取照片中的地点与时间，连接地点和回忆",
                            result: photoResult,
                            isActive: step == .photos,
                            primaryTitle: "获取相册数据",
                            primaryAction: enablePhotos,
                            secondaryTitle: "不获取",
                            secondaryAction: skipPhotos)

                        permissionCard(
                            number: 3,
                            icon: "figure.run",
                            title: "Apple 健康",
                            detail: "自动同步运动记录与路线，补全真实轨迹",
                            result: healthResult,
                            isActive: step == .health,
                            primaryTitle: "自动同步健康数据",
                            primaryAction: enableHealth,
                            secondaryTitle: "不获取",
                            secondaryAction: skipHealth)
                    }
                    .padding(.top, 28)

                    Text("数据仅保存在本机 · 无上传 · 无广告")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 22)
                        .padding(.bottom, 34)
                }
                .padding(.horizontal, 22)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: locationService.isBackgroundLocationEnabled) { _, enabled in
            if enabled { locationResult = .enabled("后台位置已开启") }
        }
        .onAppear {
            #if DEBUG
            if TestHooks.autoScan, step == .location {
                disableBackgroundLocation()
                enablePhotos()
            }
            #endif
        }
    }

    private var logo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 1.0, green: 0.35, blue: 0.42),
                             Color(red: 0.88, green: 0.16, blue: 0.27)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 88, height: 88)
        .shadow(color: Color.red.opacity(0.35), radius: 20, y: 9)
    }

    private func permissionCard(
        number: Int,
        icon: String,
        title: String,
        detail: String,
        result: PermissionResult,
        isActive: Bool,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String,
        secondaryAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isActive ? Color.red.opacity(0.22) : Color.white.opacity(0.08))
                    if isCompleted(result) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.green)
                    } else {
                        Text("\(number)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(isActive ? .white : .secondary)
                    }
                }
                .frame(width: 30, height: 30)

                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isActive ? Color.red : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(resultText(result) ?? detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)

                if case .working = result {
                    ProgressView().controlSize(.small)
                }
            }

            if isActive, !isWorking(result) {
                HStack(spacing: 10) {
                    Button(primaryTitle, action: primaryAction)
                        .buttonStyle(OnboardingPrimaryButtonStyle())
                    Button(secondaryTitle, action: secondaryAction)
                        .buttonStyle(OnboardingSecondaryButtonStyle())
                }
            }
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(isActive ? 0.09 : 0.055)))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isActive ? Color.red.opacity(0.5) : Color.white.opacity(0.06), lineWidth: 1)
        }
        .opacity(step.rawValue < number - 1 ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.2), value: step.rawValue)
    }

    private func enableBackgroundLocation() {
        guard step == .location else { return }
        locationResult = .working
        locationService.requestBackgroundLocationAuthorization { enabled in
            Task { @MainActor in
                locationResult = enabled
                    ? .enabled("后台位置已开启")
                    : .off("后台位置关闭")
                step = .photos
            }
        }
    }

    private func disableBackgroundLocation() {
        guard step == .location else { return }
        locationService.disableBackgroundLocation()
        locationResult = .off("后台位置关闭")
        step = .photos
    }

    private func enablePhotos() {
        guard step == .photos else { return }
        guard let token = LocalImportCoordinator.shared.capture() else { return }
        photoResult = .working
        scanText = "正在请求相册权限…"
        let container = context.container
        Task.detached(priority: .userInitiated) {
            let status = await PhotoScanner.requestAccess()
            guard status == .authorized || status == .limited else {
                await MainActor.run {
                    guard LocalImportCoordinator.shared.isCurrent(token) else { return }
                    photoResult = .off("未获取相册数据")
                    scanText = nil
                    advanceAfterPhotos()
                }
                return
            }

            let result = PhotoScanner.scanWithPhotos(shouldContinue: {
                LocalImportCoordinator.shared.isCurrent(token)
            }) { done, total in
                Task { @MainActor in
                    guard LocalImportCoordinator.shared.isCurrent(token) else { return }
                    scanText = total > 0 ? "正在扫描 \(done) / \(total) 张照片" : "正在扫描照片…"
                }
            }
            let saved = await PhotoStore.importPhotos(
                result.photoInfos, container: container, token: token)
            await MainActor.run {
                guard LocalImportCoordinator.shared.isCurrent(token) else { return }
                photoResult = saved.status == .completed
                    ? .enabled(ImportFeedback.summary(saved)) : .off(ImportFeedback.title(saved))
                scanText = nil
                advanceAfterPhotos()
            }
        }
    }

    private func skipPhotos() {
        guard step == .photos else { return }
        photoResult = .off("未获取相册数据")
        scanText = nil
        advanceAfterPhotos()
    }

    private func advanceAfterPhotos() {
        #if DEBUG
        if TestHooks.autoScan {
            healthResult = .off("自动化测试跳过健康数据")
            completeOnboarding()
            return
        }
        #endif
        step = .health
    }

    private func enableHealth() {
        guard step == .health else { return }
        healthResult = .working
        let container = context.container
        Task {
            let enabled = await HealthKitService.enableAutomaticSync(container: container)
            healthResult = enabled
                ? .enabled("健康数据自动同步已开启")
                : .off("未获取健康数据")
            completeOnboarding()
        }
    }

    private func skipHealth() {
        guard step == .health else { return }
        HealthKitSyncStatusStore.setEnabled(false)
        Task { await HealthKitSyncCoordinator.shared.disableAutomaticSync() }
        healthResult = .off("未获取健康数据")
        completeOnboarding()
    }

    private func completeOnboarding() {
        guard !didFinish else { return }
        didFinish = true
        step = .completed
        onDone()
    }

    private func isCompleted(_ result: PermissionResult) -> Bool {
        switch result {
        case .enabled, .off: return true
        case .pending, .working: return false
        }
    }

    private func isWorking(_ result: PermissionResult) -> Bool {
        if case .working = result { return true }
        return false
    }

    private func resultText(_ result: PermissionResult) -> String? {
        switch result {
        case .pending: return nil
        case .working: return "处理中…"
        case .enabled(let text), .off(let text): return text
        }
    }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(red: 0.9, green: 0.23, blue: 0.32).opacity(configuration.isPressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .foregroundStyle(.white)
    }
}

private struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .foregroundStyle(.secondary)
    }
}
