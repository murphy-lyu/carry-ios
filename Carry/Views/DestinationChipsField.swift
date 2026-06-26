//
//  DestinationChipsField.swift
//  Carry
//
//  多目的地输入：已选目的地渲染为可删除胶囊 chip（自动换行），输入框紧随最后一个 chip；
//  打字即检索（复用 StopSearchCompleter 城市模式 + Worker），选中一条建议 → **追加** chip（不替换）。
//  创建页 TripInfoView 与编辑页 EditTripView 共用本组件，消除两页目的地输入的重复。
//  spec: multi-destination-chips.md
//

import SwiftUI
import UIKit

struct DestinationChipsField: View {
    /// 有序结构化目的地（首=主，其余=additionalDestinations）。countryCode 空 = 未解析（自由文本）。
    @Binding var destinations: [ResolvedDestination]
    /// 输入框当前文本（未提交的自由文本）。由父视图持有 → 父视图组装 destinationCity 时可即时纳入，
    /// 不依赖失焦时机，杜绝「键盘还没收、点了创建」漏字。
    @Binding var text: String
    var placeholder: LocalizedStringKey

    @StateObject private var completer = StopSearchCompleter()
    @State private var isResolving = false
    // 普通 Bool：输入框是 IMESafeTextField（自持 UITextField first responder），焦点不能用 @FocusState
    // （无 .focused() 认领会被 SwiftUI 持续重置为 false → 每敲一字误 resignFirstResponder 收键盘）。
    @State private var inputFocused: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    /// 建议列表显示条件：输入框聚焦、文本非空、有候选、且非解析在途。
    private var showSuggestions: Bool {
        inputFocused &&
        !text.trimmingCharacters(in: .whitespaces).isEmpty &&
        !completer.results.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldContainer
            if showSuggestions {
                suggestionList
            }
        }
        .onAppear {
            // 目的地走「城市模式」：只补全国家/地区/城市，让「Tokyo→东京市」成首条、不掺同名 POI。
            completer.placeMode = true
            completer.query = text
        }
        .onDisappear { completer.tearDown() }   // 取消在途海外请求 + 停 MapKit 补全
        .onChange(of: text) { _, newValue in
            // 只读 text 喂补全器，绝不反向改写 TextField（保护中文输入法预编辑态）。
            completer.query = newValue
        }
    }

    // MARK: - Field container (chips + input, flow-wrapped)

    private var fieldContainer: some View {
        FlowLayout(spacing: 7, lineSpacing: 8, stretchLastSubview: true) {
            ForEach(destinations) { dest in
                chip(dest)
            }
            // 输入框始终是最后一个子视图（身份稳定、不随 chip 增删被增删 → 中文选词不丢字）。
            // 用 IMESafeTextField（替代原生 TextField）：修复微信输入法选词上屏后 text binding 不更新、
            // 进而不触发检索的缺陷（见 ViewModifiers.swift 的 IMESafeTextField）。focus 双向桥接到 @FocusState。
            IMESafeTextField(
                text: $text,
                font: .preferredFont(forTextStyle: .subheadline),
                returnKeyType: .done,
                isFocused: $inputFocused,
                onSubmit: { commitFreeText() }
            )
            .frame(minWidth: 110)
            .frame(height: 30)
            .overlay(alignment: .leading) {
                // 仅在「整个字段为空」时显示提示：已有 chip 时不再显示 placeholder
                // （否则它会跟在最后一个目的地 chip 旁、暗示字段为空，与已选目的地矛盾）。
                if destinations.isEmpty && text.isEmpty {
                    Text(placeholder)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: inputFocused) { _, focused in
                if !focused { commitFreeText() }   // 失焦：把残留自由文本固化为 chip，不丢
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.systemBackground).opacity(0.66))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.07),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func chip(_ dest: ResolvedDestination) -> some View {
        HStack(spacing: 4) {
            Text(dest.name)
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Button {
                removeChip(dest)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)   // 命中区足够大
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("common.remove"))
        }
        .padding(.leading, 11)
        .padding(.trailing, 3)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color(UIColor.tertiarySystemFill)))
        .overlay(
            Capsule().strokeBorder(
                Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06),
                lineWidth: 1
            )
        )
    }

    // MARK: - Suggestion list (sibling view, IME-safe — see resolve-at-input)

    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(completer.results.prefix(5).enumerated()), id: \.element.id) { index, result in
                if index > 0 {
                    Divider().padding(.leading, 12)
                }
                Button {
                    select(result)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(UIColor.systemBackground).opacity(0.66))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.07),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if isResolving {
                ZStack {
                    Color(UIColor.systemBackground).opacity(0.5)
                    ProgressView()
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .disabled(isResolving)
    }

    // MARK: - Actions

    /// 选中一条建议 → 解析权威国家码 + 坐标 → **追加** chip、清空输入框、保持聚焦继续输入下一个。
    private func select(_ suggestion: PlaceSuggestion) {
        // 同步先把焦点钉回输入框：父视图 ScrollView 的 tap-to-dismiss 手势会在本次点击里
        // 调 resignFirstResponder，同帧重置 @FocusState=true 抵消之，避免选完键盘掉下又弹回。
        inputFocused = true
        isResolving = true
        Task {
            let resolved = await completer.resolve(suggestion)
            await MainActor.run {
                isResolving = false
                guard let resolved else { return }   // 网络/上游失败 → 维持文本，走文本兜底
                appendDestination(ResolvedDestination(
                    name: resolved.name,
                    countryCode: resolved.countryCode,
                    latitude: resolved.latitude,
                    longitude: resolved.longitude
                ))
                text = ""
                completer.results = []
                inputFocused = true                  // 保持聚焦，继续加下一个
            }
        }
    }

    /// 残留自由文本固化为「未解析 chip」（仅名字，保存时由 writeDestinations 逐个解析）。
    /// 按显式标点拆分（「东京, 大阪」→ 两个 chip；含 and 的地名保持整体）。
    private func commitFreeText() {
        let names = DestinationComposer.splitFreeText(text)
        guard !names.isEmpty else { text = ""; completer.results = []; return }
        for name in names {
            appendDestination(ResolvedDestination(name: name))
        }
        text = ""
        completer.results = []
    }

    /// 追加目的地，去重（见 DestinationComposer.isDuplicate：同名+同码才算重；
    /// 两个同名不同国的城市可并存，San José CR 与 San José US 不互相吞）。
    private func appendDestination(_ dest: ResolvedDestination) {
        guard !DestinationComposer.isDuplicate(dest, in: destinations) else { return }
        destinations.append(dest)
    }

    /// 删除一个 chip；删首项时其后一项靠数组顺序自动晋升为主目的地，无需额外逻辑。
    private func removeChip(_ dest: ResolvedDestination) {
        destinations.removeAll { $0.id == dest.id }
    }
}

// MARK: - DestinationComposer（chips 组装 + 去重的单一真源，创建/编辑两页共用）

enum DestinationComposer {
    /// 是否与已有 chip 重复：同名（大小写不敏感）**且**（同国家码，或任一未解析）。
    /// 未解析项（自由文本、countryCode 空）与任何同名项视为重复 → 不重复堆叠；两个**已解析**的
    /// 同名不同国城市（码不同、均非空）则保留为两条（罕见但合法）。
    static func isDuplicate(_ candidate: ResolvedDestination, in existing: [ResolvedDestination]) -> Bool {
        existing.contains { e in
            e.name.caseInsensitiveCompare(candidate.name) == .orderedSame &&
            (e.countryCode == candidate.countryCode || e.countryCode.isEmpty || candidate.countryCode.isEmpty)
        }
    }

    /// 顺序去重（保留首个出现的——已解析 chip 天然在自由文本之前）。
    static func dedup(_ chips: [ResolvedDestination]) -> [ResolvedDestination] {
        var out: [ResolvedDestination] = []
        for chip in chips where !isDuplicate(chip, in: out) { out.append(chip) }
        return out
    }

    /// chips + 残留输入文本 → 去重后的有序列表。残留文本按**显式标点**拆成多个未解析 chip。
    /// 创建/编辑两页都用它派生 destinationCity 文本与传给 store 的结构化数组，保证两者一致。
    static func allChips(_ chips: [ResolvedDestination], pendingText: String) -> [ResolvedDestination] {
        var result = chips
        for name in splitFreeText(pendingText) {
            result.append(ResolvedDestination(name: name))
        }
        return dedup(result)
    }

    /// 自由文本按**显式标点分隔符**（逗号/顿号/斜杠/加号/&）拆分，但**不**拆 " and "/" 和 "——
    /// 标点是用户「多个目的地」的明确意图（粘贴「阿姆斯特丹、维也纳」→ 两个）；而含 and 的地名
    /// （Bosnia and Herzegovina / Trinidad and Tobago）必须保持整体、不被误拆。
    /// 选中检索建议得到的 chip 永远是单一地点、不走此拆分。
    static func splitFreeText(_ text: String) -> [String] {
        var tokens = [text]
        for sep in [",", "，", "、", "/", "／", "&", "＆", "+", "＋"] {
            tokens = tokens.flatMap { $0.components(separatedBy: sep) }
        }
        return tokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }
}
