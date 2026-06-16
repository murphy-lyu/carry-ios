//
//  ItineraryDetailRows.swift
//  Carry
//
//  行程「只读详情」页共用的信息行组件（地点 / 住宿 / 交通详情共用，spec: itinerary-entity-detail-unify.md）。
//  - DetailInfoRow：图标 + 内容（内容自明、不需标签）。
//  - LabeledDetailRow：图标 + 小标签 + 值（仅用于需消歧的字段，如入住/退房两个日期、出发/到达）。
//  - CopyableDetailRow：图标 + 内容 + 点按复制（地址、确认号等高频要复制的值）。
//

import SwiftUI

/// 详情页头部：图标圈 + 标题 + 「···」操作菜单（编辑 / 删除）+ 关闭 X。
/// 地点 / 住宿 / 交通详情共用。删除提到 `···` 一步可达（不再藏在编辑页里），破坏性红色、
/// 与底部 Edit 主按钮分工：常做的编辑在底部单手可达，破坏性删除收进菜单、好找又不易误触。
struct DetailSheetHeader: View {
    let iconSystemName: String
    let iconTint: Color
    let title: String
    /// 删除项文案 key（各实体不同：地点 / 住宿 / 交通）。
    let deleteLabelKey: String
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var confirmingDelete = false

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
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            Menu {
                Button { onEdit() } label: { Label("itinerary.stop.detail.edit", systemImage: "pencil") }
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label(LocalizedStringKey(deleteLabelKey), systemImage: "trash")
                }
            } label: {
                circleGlyph("ellipsis")
            }
            .accessibilityLabel(Text("common.more"))
            Button { onClose() } label: { circleGlyph("xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("common.close"))
        }
        // 删除二次确认：用正式 alert（居中弹窗），保证「取消 + 删除」两个按钮都在、各设备一致。
        .alert(LocalizedStringKey(deleteLabelKey), isPresented: $confirmingDelete) {
            Button("common.cancel", role: .cancel) {}
            Button("common.delete", role: .destructive) { onDelete() }
        } message: {
            Text("common.delete_confirm")
        }
    }

    /// 30pt 视觉玻璃圆 + 44pt 触达，与全屏地图 / 设置的圆形按钮一致。
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

/// 图标 + 内容。内容靠图标表意（费用/晚数等），不加标签——与全 app 详情页「只显内容」一致。
struct DetailInfoRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 图标 + 小标签 + 值。仅用于**需消歧**的字段：入住/退房（两个日期不标会混）、出发/到达。
struct LabeledDetailRow: View {
    let icon: String
    let labelKey: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(labelKey))
                    .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.subheadline, design: .rounded)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 图标 + 内容 + 点按复制（带触感 + 「已复制」反馈）。用于地址、确认号等高频复制值——
/// 如把确认号发给同行伙伴先办入住。复用既有 `address_copied` / `copy_hint` 文案。
struct CopyableDetailRow: View {
    let icon: String
    let text: String

    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.2)) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeInOut(duration: 0.2)) { copied = false }
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.primary)
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
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(text))
        .accessibilityHint(Text("itinerary.stop.detail.copy_hint"))
    }
}
