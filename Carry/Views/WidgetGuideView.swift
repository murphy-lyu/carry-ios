import SwiftUI

#if !targetEnvironment(macCatalyst)
/// 设置 → 小部件：告知用户 Carry 有桌面小部件，并展示它长什么样。
/// 不做分步添加引导——各 iOS 版本添加方式不同，分步反而易误导；只给一张预览图 +
/// 一句版本无关的添加提示（长按主屏幕）。视觉对齐 `LiveActivitySettingsView`。
///
/// 图片槽位：预览图通过 `guideImage(_:)` 渲染——资源不存在时显示带资源名的占位框，
/// 做好真图后以 `WidgetPreview` 命名加入 `Assets.xcassets` 即自动替换，无需改代码。
struct WidgetGuideView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 小部件预览图（占位）
                guideImage("WidgetPreview", placeholderAspect: 16.0 / 10.0)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Text("settings.widget.description")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1.6)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(Text("settings.widget.entry"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    /// 图片槽：资源存在时显示真图；否则显示带资源名的虚线占位框。
    /// 做好真图后以 `name` 命名加入 Assets.xcassets 即自动替换，无需改代码。
    @ViewBuilder
    private func guideImage(_ name: String, placeholderAspect: CGFloat) -> some View {
        if UIImage(named: name) != nil {
            Image(name)
                .resizable()
                .scaledToFit()
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.04) : Color.primary.opacity(0.035))
                .aspectRatio(placeholderAspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .foregroundStyle(.secondary.opacity(0.35))
                )
                .overlay(
                    VStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.secondary.opacity(0.5))
                        // 技术性占位标记（资源名），加入真图后不再显示，不属于用户文案。
                        Text(verbatim: name)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                )
        }
    }
}
#endif
