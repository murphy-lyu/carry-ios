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
