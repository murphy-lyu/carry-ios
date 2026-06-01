import SwiftUI

#if !targetEnvironment(macCatalyst)
/// 设置 → 小部件：告知用户 Carry 有桌面小部件，并图文引导如何添加到主屏幕。
/// 视觉与交互对齐 `LiveActivitySettingsView`（同款卡片底色/描边、分组背景）。
///
/// 图片槽位说明：所有引导图都通过 `guideImage(_:)` 渲染——资源不存在时显示带资源名的
/// 占位框，做好真图后以对应名称加入 `Assets.xcassets` 即自动替换，无需改代码。
/// 需要的资源名：`WidgetPreview`（顶部小部件预览）、`WidgetGuideStep1/2/3`（三步截图）。
struct WidgetGuideView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var cardFill: Color {
        colorScheme == .dark
            ? Color(UIColor.secondarySystemGroupedBackground).opacity(0.72)
            : Color(UIColor.secondarySystemGroupedBackground)
    }

    private var cardStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.045)
            : Color.primary.opacity(0.05)
    }

    private struct Step: Identifiable {
        let id = UUID()
        let titleKey: LocalizedStringKey
        let captionKey: LocalizedStringKey
        let imageName: String
    }

    private let steps: [Step] = [
        Step(titleKey: "settings.widget.step1.title",
             captionKey: "settings.widget.step1.caption",
             imageName: "WidgetGuideStep1"),
        Step(titleKey: "settings.widget.step2.title",
             captionKey: "settings.widget.step2.caption",
             imageName: "WidgetGuideStep2"),
        Step(titleKey: "settings.widget.step3.title",
             captionKey: "settings.widget.step3.caption",
             imageName: "WidgetGuideStep3")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 顶部：小部件预览图（占位）
                ZStack {
                    Color(.secondarySystemGroupedBackground)
                    guideImage("WidgetPreview", placeholderAspect: 16.0 / 9.0)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Text("settings.widget.description")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1.6)

                VStack(spacing: 14) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        stepCard(number: index + 1, step: step)
                    }
                }
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

    private func stepCard(number: Int, step: Step) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(number)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color(UIColor.systemBackground))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.85)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.titleKey)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(step.captionKey)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineSpacing(1.4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            guideImage(step.imageName, placeholderAspect: 4.0 / 3.0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(cardStroke, lineWidth: 1)
                )
        )
    }

    /// 图片槽：资源存在时显示真图；否则显示带资源名的虚线占位框。
    /// 做好真图后以 `name` 命名加入 Assets.xcassets 即自动替换，无需改代码。
    @ViewBuilder
    private func guideImage(_ name: String, placeholderAspect: CGFloat) -> some View {
        if UIImage(named: name) != nil {
            Image(name)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
