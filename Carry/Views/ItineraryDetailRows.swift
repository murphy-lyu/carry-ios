//
//  ItineraryDetailRows.swift
//  Carry
//
//  行程「只读详情」页共用组件（地点 / 住宿 / 交通详情共用，spec: itinerary-entity-detail-unify.md）。
//  可读性改造（学 Tripsy）：每行「图标 + 小标签 + 值」（不再纯图标）；信息裹进圆角分组卡、
//  行间细分隔线、加大留白。`···` 菜单只留「移除」（编辑用底部主按钮，去冗余）。
//

import SwiftUI

// MARK: - 复制 Toast（详情卡内「轻点复制」的居中反馈，由 DetailSheetScaffold 注入并渲染）

private struct CarryCopyToastKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}
extension EnvironmentValues {
    /// 详情卡内「轻点复制」后弹的居中 Toast 触发器；深层行（CopyableDetailRow）读它、骨架渲染它。
    var carryCopyToast: (String) -> Void {
        get { self[CarryCopyToastKey.self] }
        set { self[CarryCopyToastKey.self] = newValue }
    }
}

/// 居中复制反馈 Toast：磨砂底 + 绿勾 + 文案，自动消隐（对标 Tripsy 的优雅反馈）。不挡手势。
private struct CarryCopyToastView: View {
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green)
            Text(text)
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.carryCardShadow, radius: 16, x: 0, y: 6)
        .allowsHitTesting(false)
    }
}

/// 详情浮层骨架（地点/交通/住宿共用）：**头部钉在顶部不随滚动**，仅下方卡片区滚动；
/// detent 贴合内容高度（量头部 + 内容求和），长内容在内部滚动。
/// **刻意只给单一 `.height` detent、不含 `.large`**：系统 `.large`（满屏）会触发 iOS 26
/// 把弹层「脱离成带两侧边距的浮动卡片」——这正是高内容详情弹出即缩的根因；不进 `.large` 即不缩。
struct DetailSheetScaffold<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var toastText: String?
    @State private var toastToken = 0

    private var detents: Set<PresentationDetent> {
        guard headerHeight > 0, contentHeight > 0 else { return [.medium] }
        // 自算高度走单一真源 cappedContentHeight：钳在屏高以下，绝不顶到满屏触发 iOS 26 脱离（斜滚根因）。
        return [.cappedContentHeight(headerHeight + contentHeight + 20)]   // +20 ≈ 底部气口
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 4)   // 头部底部留白收到 4：首卡阴影余量改由下方内容区 .top 承担，「头→首卡」≈ 卡间距 16
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(heightReader($headerHeight))
                .background(Color.carryCanvas)   // 不透明分组画布：滚动内容从下穿过、不透字；与卡片拉开层次
            ScrollView {
                content
                    .padding(.horizontal, 20)
                    // 顶部 inset 12：让首卡向上扩散的柔性阴影（r16）渲染在 ScrollView 裁切边界之内，不被顶部切掉。
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(heightReader($contentHeight))
            }
        }
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.carryCanvas)
        .environment(\.carryCopyToast, showCopyToast)
        .overlay(alignment: .center) {
            if let toastText {
                CarryCopyToastView(text: toastText)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
    }

    /// 轻点复制后弹居中 Toast，1.4s 自动消隐；token 防连点时被前一次的延时提前关掉。
    private func showCopyToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        withAnimation(.spring(duration: 0.3, bounce: 0.2)) { toastText = text }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if token == toastToken {
                withAnimation(.easeOut(duration: 0.25)) { toastText = nil }
            }
        }
    }

    private func heightReader(_ binding: Binding<CGFloat>) -> some View {
        GeometryReader { g in
            Color.clear
                .onAppear { binding.wrappedValue = g.size.height }
                .onChange(of: g.size.height) { _, h in binding.wrappedValue = h }
        }
    }
}

/// 详情页头部：图标圈 + 标题 + 关闭 X。**动作（编辑/移除）全部收到底部 `DetailActionFooter`**，
/// 顶部只留单一关闭按钮——右上角不再「··· + X」两枚，更克制（对标 Apple 地图地点卡 / 日历事件详情）。
struct DetailSheetHeader: View {
    let iconSystemName: String
    let iconTint: Color
    let title: String
    /// 可选副标题：承载"这张卡是哪个事件"的语境（如租车「取车 / 还车」），与时间轴行一致；
    /// 移到标题层后，卡片内容只留实质信息（地址/时间），更易读。
    var subtitle: String? = nil
    let onClose: () -> Void

    private var hasSubtitle: Bool { !(subtitle?.isEmpty ?? true) }

    var body: some View {
        // 三元素（图标圈 / 标题块 / 关闭 X）真正按中心对齐——共享一条中线，不再用 `.top` + 手动 padding 凑近似。
        // 标题最多两行（标题 + 可选副标题），居中读起来稳；超长标题由 VStack 自身换行，图标/X 仍居整块中心。
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                // 0.20（原 0.15）：详情画布改分组灰后，15% 淡填充在灰底上对比变弱、图标圈发灰；
                // 提到 0.20 让它在灰画布上重新「站住」，并与右侧白色玻璃按钮区分开。
                Circle().fill(iconTint.opacity(0.20))
                Image(systemName: iconSystemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconTint)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle, hasSubtitle {
                    Text(subtitle)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { onClose() } label: { circleGlyph("xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("common.close"))
        }
    }

    private func circleGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .glassCircleButton()
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

/// 信息分组卡：把若干行裹进圆角卡，行间用细分隔线（左缩进对齐文字列），统一留白。
/// 行本身自带上下内边距（成「单元格」），此处只负责容器 + 分隔线。
struct DetailRowGroup: View {
    let rows: [AnyView]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                if i > 0 { Divider().padding(.leading, 34) }
                rows[i]
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)            // 卡顶/底气口，首末行不贴边
        .carryCard(cornerRadius: CarryRadius.card)
    }
}

/// 带标签的信息行：图标 + 小标签（上）+ 值（下）。标签让每行自解释（学 Tripsy）。
struct LabeledDetailRow: View {
    let icon: String
    let labelKey: String
    let value: String

    var body: some View {
        // 图标与「标签+值」整体垂直居中（不贴标签顶）。
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(labelKey))
                    .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.subheadline, design: .rounded)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

/// 带标签 + 点按拨号的信息行（电话）。点击直接拨打（tel:），方便行程中联系。
struct CallableDetailRow: View {
    let labelKey: String
    let phone: String

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            let digits = phone.filter { $0.isNumber || $0 == "+" }
            if !digits.isEmpty, let url = URL(string: "tel://\(digits)") { openURL(url) }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "phone")
                    .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(labelKey))
                        .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
                    // 电话值用烟蓝 = 「可点拨号」的信号（对标 Apple/Tripsy 链接色），替代尾部拨号图标。
                    Text(phone)
                        .font(.system(.subheadline, design: .rounded)).foregroundStyle(CarryAccent.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(phone))
    }
}

/// 带标签 + 点按复制的信息行（地址、确认号等高频复制值）。触感 + 「已复制」反馈。
struct CopyableDetailRow: View {
    let icon: String
    let labelKey: String
    let value: String

    /// 复制反馈走骨架的居中 Toast（替代尾部图标 + 行内「已复制」），卡片更干净。
    @Environment(\.carryCopyToast) private var showToast

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showToast(NSLocalizedString("itinerary.stop.detail.address_copied", comment: ""))
        } label: {
            // 整行轻点即复制；不再有尾部复制图标——「可复制」靠交互 + Toast 表达，卡片回归纯信息。
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(labelKey))
                        .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(.subheadline, design: .rounded)).foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(value))
        .accessibilityHint(Text("itinerary.stop.detail.copy_hint"))
    }
}

/// 备注行：图标 + 「备注」标签 + 可展开/收起长文（`ExpandableText`，可长按选取复制）。
struct NoteDetailRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "note.text")
                .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("itinerary.transport.field.note")
                    .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
                ExpandableText(text: text, font: .system(.subheadline, design: .rounded), collapsedLineLimit: 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
    }
}

// MARK: - DetailActionFooter

/// 详情页底部动作收尾（替代整宽 Edit 大色块）：克制「✎ 编辑」胶囊 + 下方安静红「移除」（带二次确认）。
/// 对标 Apple 日历事件详情底部（编辑 + 删除事件）——把动作降到配得上「编辑 + 移除」两动作的最轻 chrome：
/// 编辑是主动作、贴合内容宽的烟蓝胶囊（不再满宽大块）；移除是低频破坏性动作、退作安静红字、确认后才执行。
struct DetailActionFooter: View {
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 14) {
            Button(action: onEdit) {
                HStack(spacing: 6) {
                    Image(systemName: "pencil").font(.system(size: 14, weight: .semibold))
                    Text("itinerary.stop.detail.edit")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 30)
                .padding(.vertical, 12)
                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Button { confirmingDelete = true } label: {
                Text("common.remove")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(Color(.systemRed))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .alert(Text("itinerary.detail.remove_confirm"), isPresented: $confirmingDelete) {
            Button("common.cancel", role: .cancel) {}
            Button("common.remove", role: .destructive, action: onDelete)
        }
    }
}
