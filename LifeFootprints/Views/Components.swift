import SwiftUI

/// 深色玻璃卡片样式
struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
}

/// 冷启动品牌过渡：用路线符号承接大数据加载，避免只有系统转圈的等待感。
struct BrandLoadingView: View {
    let accent: Color
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.035, green: 0.045, blue: 0.07),
                                    Color(red: 0.075, green: 0.055, blue: 0.09)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(accent.opacity(0.14))
                        .frame(width: 92, height: 92)
                        .scaleEffect(breathing ? 1.08 : 0.96)
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(accent.gradient)
                        .frame(width: 72, height: 72)
                        .shadow(color: accent.opacity(0.35), radius: 18, y: 6)
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.system(size: 31, weight: .bold))
                        .foregroundStyle(.black.opacity(0.82))
                }
                VStack(spacing: 5) {
                    Text("Tracé")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                    Text("正在整理你的旅程")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                ProgressView()
                    .tint(accent)
                    .scaleEffect(0.85)
            }
        }
        .onAppear {
            // Reduce Motion 下只保留静态品牌页与 ProgressView，不做循环呼吸动画。
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}
