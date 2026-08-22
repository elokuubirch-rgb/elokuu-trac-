import SwiftUI
import UIKit

/// 液态玻璃 Tab Bar：
/// - 点击：高亮块动画滑到目标 Tab（原有行为）。
/// - 按住拖动：高亮块 1:1 跟手（dragProgress 连续 0...2），
///   三个 Tab 的图标/文字按 weight = max(0, 1 - |progress - index|) 连续渐变；
///   松手按速度预测吸附到最近 Tab 后，才真正提交 selectedTab（页面常驻结构不受影响）。
struct MainLiquidTabBar: View {
    @Binding var selectedTab: AppTab
    let accent: Color
    let onMapDoubleTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// nil=非拖动；否则为 0.0...2.0 连续进度（允许 0.42 这类中间值）
    @State private var dragProgress: Double? = nil
    @State private var isDragging = false
    @State private var dragStartProgress: Double = 0
    /// 快速拖动时的轻微水平形变（1.0...1.05），松手回弹
    @State private var stretchX: CGFloat = 1
    /// 点击切换时的短暂拉伸（沿用原交互）
    @State private var stretching = false
    @State private var morphTask: Task<Void, Never>?

    private let items: [(AppTab, String, LocalizedStringKey)] = [
        (.map, "location.north.circle", "地图"),
        (.review, "photo.on.rectangle.angled", "回顾"),
        (.statistics, "chart.line.uptrend.xyaxis", "统计")
    ]

    private var displayProgress: Double {
        dragProgress ?? Double(selectedTab.rawValue)
    }

    private func weight(for tab: AppTab) -> Double {
        max(0, 1 - abs(displayProgress - Double(tab.rawValue)))
    }

    var body: some View {
        GeometryReader { proxy in
            let itemWidth = proxy.size.width / CGFloat(items.count)
            let indicatorWidth = min(max(itemWidth * 0.66, 54), 70)
            ZStack(alignment: .leading) {
                AdaptiveGlassBackground(reduceTransparency: reduceTransparency)

                LiquidSelectionIndicator(accent: accent,
                                         reduceTransparency: reduceTransparency)
                    .frame(width: indicatorWidth, height: 46)
                    .scaleEffect(x: reduceMotion ? 1 : (isDragging ? stretchX : (stretching ? 1.12 : 1)),
                                 y: reduceMotion ? 1 : (isDragging ? 0.98 : 1))
                    .offset(x: itemWidth * displayProgress
                            + (itemWidth - indicatorWidth) / 2)
                    // 只在“点击切换”时动画；拖动期间由 dragProgress 无动画驱动（1:1 跟手）。
                    .animation(reduceMotion ? .easeOut(duration: 0.14) : .easeInOut(duration: 0.27),
                               value: selectedTab)
                    .accessibilityHidden(true)

                HStack(spacing: 0) {
                    ForEach(items, id: \.0) { tab, icon, label in
                        MainTabItem(tab: tab, icon: icon, label: label,
                                    weight: weight(for: tab),
                                    accent: accent) {
                            select(tab)
                        }
                        .frame(width: itemWidth, height: proxy.size.height)
                        .onTapGesture(count: 2) {
                            if tab == .map { onMapDoubleTap() }
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .highPriorityGesture(reduceMotion ? nil : dragGesture(itemWidth: itemWidth))
        }
        .frame(width: min(UIScreen.main.bounds.width * 0.69, 306), height: 62)
        .padding(.bottom, 8)
        .onDisappear { morphTask?.cancel() }
    }

    // MARK: - 拖动（高亮块跟手，松手吸附后才提交 selectedTab）

    private func dragGesture(itemWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    dragStartProgress = displayProgress
                }
                let raw = dragStartProgress + Double(value.translation.width) / Double(itemWidth)
                dragProgress = min(max(raw, 0), Double(items.count - 1))
                // 轻微液态形变：速度越快水平越拉伸（上限 1.05）
                let speed = abs(value.velocity.width)
                stretchX = min(1 + speed * 0.00002, 1.05)
            }
            .onEnded { value in
                guard let progress = dragProgress else {
                    isDragging = false
                    return
                }
                // 速度预测：预测结束位置 + 快甩时向甩动方向偏 0.3 格
                let extraMovement = value.predictedEndTranslation.width - value.translation.width
                var projected = progress + Double(extraMovement) / Double(itemWidth)
                if abs(extraMovement) > 30 {
                    projected += 0.3 * (extraMovement > 0 ? 1 : -1)
                }
                let clamped = Int(min(max(projected.rounded(), 0), Double(items.count - 1)))
                let snapped = AppTab(rawValue: clamped) ?? .map
                if snapped != selectedTab {
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                    dragProgress = Double(clamped)
                    stretchX = 1
                } completion: {
                    isDragging = false
                    selectedTab = snapped
                    dragProgress = nil
                }
            }
    }

    // MARK: - 点击切换（原有行为）

    private func select(_ tab: AppTab) {
        guard selectedTab != tab else { return }
        morphTask?.cancel()
        UISelectionFeedbackGenerator().selectionChanged()
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.14)) { selectedTab = tab }
            return
        }
        stretching = true
        withAnimation(.easeInOut(duration: 0.27)) { selectedTab = tab }
        morphTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(170))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.12)) { stretching = false }
        }
    }
}

private struct MainTabItem: View {
    let tab: AppTab
    let icon: String
    let label: LocalizedStringKey
    /// 0...1 连续选中权重：拖动时按 |progress - index| 连续插值
    let weight: Double
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.50))
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(accent)
                        .opacity(weight)
                }
                ZStack {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.50))
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(accent)
                        .opacity(weight)
                }
            }
            .scaleEffect(1 + 0.04 * weight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabItemPressStyle())
        .accessibilityLabel(label)
        .accessibilityValue(weight >= 0.999 ? Text("已选择") : Text(""))
        .accessibilityAddTraits(weight >= 0.999 ? .isSelected : [])
    }
}

/// 按压反馈：纯视觉，不与容器拖动手势抢触控。
private struct TabItemPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct LiquidSelectionIndicator: View {
    let accent: Color
    let reduceTransparency: Bool

    var body: some View {
        Group {
            if reduceTransparency {
                Capsule().fill(accent.opacity(0.16))
            } else if #available(iOS 26.0, *) {
                Capsule().fill(.clear)
                    .glassEffect(.regular.tint(accent.opacity(0.18)).interactive(), in: Capsule())
            } else {
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(accent.opacity(0.13)))
            }
        }
        .overlay(Capsule().stroke(accent.opacity(0.12), lineWidth: 0.5))
    }
}

private struct AdaptiveGlassBackground: View {
    let reduceTransparency: Bool

    var body: some View {
        Group {
            if reduceTransparency {
                Capsule().fill(Color(uiColor: .secondarySystemBackground).opacity(0.96))
            } else if #available(iOS 26.0, *) {
                Capsule().fill(.clear)
                    .glassEffect(.regular.interactive(), in: Capsule())
            } else {
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(Color.black.opacity(0.07)))
            }
        }
        .overlay(Capsule().stroke(Color.white.opacity(0.09), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.13), radius: 10, y: 4)
    }
}
