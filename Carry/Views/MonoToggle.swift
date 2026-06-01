import SwiftUI

/// 黑白主题开关。iOS 原生 `Toggle` 的滑块恒为白色且无法改色——在黑白主题的深色模式下，
/// 开启态轨道为白（`.primary`）时白滑块会被吞掉，看起来是个纯白胶囊。本组件自定义滑块颜色，
/// 保证两态在黑白下都清晰：
/// - 开：轨道 `.primary`（黑/白自适应）+ 滑块 `systemBackground`（白/黑，恒与轨道反色）
/// - 关：轨道 `systemGray4` + 滑块白（带阴影，浅色下也有边界）
struct MonoToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Color.primary : Color(.systemGray4))
            .frame(width: 51, height: 31)
            .overlay(
                Circle()
                    .fill(isOn ? Color(.systemBackground) : .white)
                    .frame(width: 27, height: 27)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, x: 0, y: 1)
                    .offset(x: isOn ? 10 : -10)
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isOn)
            .contentShape(Capsule())
            .onTapGesture { isOn.toggle() }
            .accessibilityRepresentation { Toggle(isOn: $isOn) { EmptyView() } }
    }
}
