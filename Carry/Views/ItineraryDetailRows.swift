//
//  ItineraryDetailRows.swift
//  Carry
//
//  行程「只读详情」页共用组件（地点 / 住宿 / 交通详情共用，spec: itinerary-entity-detail-unify.md）。
//  可读性改造（学 Tripsy）：每行「图标 + 小标签 + 值」（不再纯图标）；信息裹进圆角分组卡、
//  行间细分隔线、加大留白。`···` 菜单只留「移除」（编辑用底部主按钮，去冗余）。
//

import SwiftUI

/// 详情浮层骨架（地点/交通/住宿共用）：**头部钉在顶部不随滚动**，仅下方卡片区滚动；
/// 同时保留「短内容贴合高度」——分别量头部高 + 内容高求和设 detent（不撑空、长则封顶 .large 滚动）。
/// 解决「内容长时滚动顶部关闭键也滚走」的体验问题。
struct DetailSheetScaffold<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    private var detents: Set<PresentationDetent> {
        guard headerHeight > 0, contentHeight > 0 else { return [.medium, .large] }
        return [.height(headerHeight + contentHeight + 20), .large]   // +20 ≈ 底部气口
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(heightReader($headerHeight))
                .background(Color(UIColor.systemBackground))   // 不透明：滚动内容从下面穿过、不透字
            ScrollView {
                content
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(heightReader($contentHeight))
            }
        }
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(UIColor.systemBackground))
    }

    private func heightReader(_ binding: Binding<CGFloat>) -> some View {
        GeometryReader { g in
            Color.clear
                .onAppear { binding.wrappedValue = g.size.height }
                .onChange(of: g.size.height) { _, h in binding.wrappedValue = h }
        }
    }
}

/// 详情页头部：图标圈 + 标题 + 「···」菜单（仅「移除」，破坏性，带二次确认）+ 关闭 X。
/// 编辑入口在底部主按钮（单手可达），不在此重复。
struct DetailSheetHeader: View {
    let iconSystemName: String
    let iconTint: Color
    let title: String
    /// 可选副标题：承载"这张卡是哪个事件"的语境（如租车「取车 / 还车」），与时间轴行一致；
    /// 移到标题层后，卡片内容只留实质信息（地址/时间），更易读。
    var subtitle: String? = nil
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var confirmingDelete = false

    private var hasSubtitle: Bool { !(subtitle?.isEmpty ?? true) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(iconTint.opacity(0.15))
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
            .padding(.top, hasSubtitle ? 2 : 6)
            Menu {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("common.remove", systemImage: "trash")
                }
            } label: {
                circleGlyph("ellipsis")
            }
            .accessibilityLabel(Text("common.more"))
            Button { onClose() } label: { circleGlyph("xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("common.close"))
        }
        // 移除二次确认：柔和通用文案 + 取消/移除两按钮，各设备恒在。
        .alert(Text("itinerary.detail.remove_confirm"), isPresented: $confirmingDelete) {
            Button("common.cancel", role: .cancel) {}
            Button("common.remove", role: .destructive) { onDelete() }
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
        .padding(.horizontal, 14)
        .padding(.vertical, 4)            // 卡顶/底气口，首末行不贴边
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
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
                    Text(phone)
                        .font(.system(.subheadline, design: .rounded)).foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "phone.arrow.up.right")
                    .font(.system(size: 13)).foregroundStyle(.tertiary)
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

    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.2)) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeInOut(duration: 0.2)) { copied = false }
            }
        } label: {
            // 图标、复制按钮均与「标签+值」整体垂直居中（复制图标不再飘在标签行）。
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
                if copied {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark")
                        Text("itinerary.stop.detail.address_copied")
                    }
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(.green)
                    .transition(.opacity)
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13)).foregroundStyle(.tertiary)
                }
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
