//
//  ItineraryDetailRows.swift
//  Carry
//
//  行程「只读详情」页共用组件（地点 / 住宿 / 交通详情共用，spec: itinerary-entity-detail-unify.md）。
//  可读性改造（学 Tripsy）：每行「图标 + 小标签 + 值」（不再纯图标）；信息裹进圆角分组卡、
//  行间细分隔线、加大留白。`···` 菜单只留「移除」（编辑用底部主按钮，去冗余）。
//

import SwiftUI
import UIKit

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
struct DetailSheetScaffold<Header: View, Content: View, Footer: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    /// 底部**悬浮动作条**（编辑/移除）：钉在底部、内容从其身后滑过 → 毛玻璃实时模糊，原生工具条质感
    /// （对标 Tripsy / Apple 地图底栏）。不放进滚动内容里（那样会跟着滚走、且是平卡、没有玻璃透叠）。
    @ViewBuilder var footer: Footer

    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @State private var selectedDetent: PresentationDetent = .height(UIScreen.main.bounds.height * 0.50)
    @State private var toastText: String?
    @State private var toastToken = 0

    private let collapsedH = UIScreen.main.bounds.height * 0.50
    private let expandedMaxH = UIScreen.main.bounds.height * 0.85

    // 始终两档：初始固定 50%，展开 = min(内容实际高, 90%)。
    // 这样无论内容多少，第一眼高度一致（消除随机感），上滑才展开。
    private var detents: Set<PresentationDetent> {
        let idealH = headerHeight + contentHeight + footerHeight + 8
        let expandedH = idealH > 0 ? min(idealH, expandedMaxH) : expandedMaxH
        return [.height(collapsedH), .height(expandedH)]
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
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(heightReader($contentHeight))
            }
            .frame(maxWidth: .infinity)
            // 底部悬浮动作条 = 原生 `safeAreaInset`：框架把内容**顶到栏之上**（不再渗到栏下 / 不从 home indicator 区穿出）。
            // `bottomBarFade`：内容在栏上沿柔和淡出 + 渐变垫底**自带 ignoresSafeArea、延伸到屏幕底盖住 home indicator**
            // （与首页/行程列表底栏同款单一真源）。顺框架、不再手动 overlay 对抗安全区。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer
                    .padding(.horizontal, 20)
                    .bottomBarFade(Color.carryCanvas)
                    .background(heightReader($footerHeight))
            }
        }
        .presentationDetents(detents, selection: $selectedDetent)
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

    @State private var titleHeight: CGFloat = 0
    @State private var titleOneLineHeight: CGFloat = 0

    private var hasSubtitle: Bool { !(subtitle?.isEmpty ?? true) }
    private let titleFont = Font.system(.title3, design: .rounded).weight(.semibold)
    /// 标题是否折行（如超长店名）。判据：实测标题高 > 单行高（同字体强制 1 行的隐藏探针）。
    private var titleWraps: Bool { titleHeight > titleOneLineHeight + 1 }

    var body: some View {
        // 对齐自适应：标题**单行** → 图标/X 与「标题+副标题」块**居中**（短标题最稳，对标 Apple 地图地点卡）；
        // 标题**折行**（2+ 行）→ 改**顶对齐**，让图标/X 贴第一行、不下沉到中段（避免居中时图标飘到第 2 行旁）。
        HStack(alignment: titleWraps ? .top : .center, spacing: 12) {
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
                // 标题/副标题可选取复制：长按 → 系统原生「拷贝」菜单（用户自己点）。承载标题里的身份字段
                // （航班号 / 酒店名 / 地点名 / 活动名 / 租车公司）的复制，与字段行「长按即复制」是两种复制形式。
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .background(heightReader($titleHeight))   // 量标题实际高（含折行）
                if let subtitle, hasSubtitle {
                    Text(subtitle)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { onClose() } label: { circleGlyph("xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("common.close"))
        }
        // 隐藏单行探针：同字体强制 1 行，量「单行高」作折行判据（高度只读、不影响布局）。
        .background(
            Text(title).font(titleFont).lineLimit(1)
                .hidden()
                .background(heightReader($titleOneLineHeight))
        )
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

    private func heightReader(_ binding: Binding<CGFloat>) -> some View {
        GeometryReader { g in
            Color.clear
                .onAppear { binding.wrappedValue = g.size.height }
                .onChange(of: g.size.height) { _, h in binding.wrappedValue = h }
        }
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
    /// 可选右侧值（如入住/退房的时刻）：与主值分列——主值答「哪一天」靠左，trailing 答「几点」靠右、
    /// 等宽数字竖直对齐，避免用中点把日期+时间黏成一串（对标 Apple 行程表/票据的列式排版）。
    var trailing: String? = nil

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
            if let trailing {
                // 右列时刻：与主值同级（primary）、等宽数字，跨行竖直对齐成正式时间列。
                Text(trailing)
                    .font(.system(.subheadline, design: .rounded)).foregroundStyle(.primary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

/// 长按即复制：复制 + 轻震 + 居中「已复制」Toast + VoiceOver「拷贝」自定义动作（长按对旁白不可达，靠它兜底）。
/// 详情卡内所有「可复制值」统一用它——值字段长按复制，轻点留给本职操作（拨号 / 打开链接 / 无）。
private struct LongPressCopy: ViewModifier {
    let value: String
    @Environment(\.carryCopyToast) private var showToast
    private func copy() {
        guard !value.isEmpty else { return }
        UIPasteboard.general.string = value
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // 复用既有通用「Copied/已复制」（其值本就是通用复制成功，非「地址已复制」）。
        showToast(NSLocalizedString("itinerary.stop.detail.address_copied", comment: ""))
    }
    func body(content: Content) -> some View {
        content
            .onLongPressGesture { copy() }
            .accessibilityAction(named: Text("itinerary.detail.copy_action")) { copy() }
    }
}

extension View {
    /// 给任意「承载可复制文本」的视图加「长按复制」。见 `LongPressCopy`。
    func longPressCopy(_ value: String) -> some View { modifier(LongPressCopy(value: value)) }
}

/// 带标签 + 点按拨号的信息行（电话）。**轻点拨号**（tel:）、**长按复制号码**（粘到聊天/通讯录）。
struct CallableDetailRow: View {
    let labelKey: String
    let phone: String

    @Environment(\.openURL) private var openURL

    private func call() {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        if !digits.isEmpty, let url = URL(string: "tel://\(digits)") { openURL(url) }
    }

    var body: some View {
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
        .onTapGesture { call() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { call() }   // 旁白默认激活 = 拨号
        .longPressCopy(phone)             // 旁白「拷贝」动作 = 复制号码
    }
}

/// 带标签 + **长按复制**的信息行（地址、确认号、车牌等高频复制值）。轻点不动作（留给本职/避免滚动误触）；
/// 长按 → 复制 + 触感 + 居中「已复制」Toast。
struct CopyableDetailRow: View {
    let icon: String
    let labelKey: String
    let value: String

    var body: some View {
        // 不再有尾部复制图标——「可复制」靠长按交互 + Toast 表达，卡片回归纯信息。
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
        .accessibilityElement(children: .combine)
        .longPressCopy(value)
    }
}

/// 带标签 + 点按打开的链接行（日历事件 / 附件 URL）。烟蓝值 = 「可点打开」信号（与电话行同一约定）。
/// 裸域名（无 scheme）自动补 https://，避免 openURL 拿到相对 URL 打不开。
struct LinkDetailRow: View {
    let labelKey: String
    let urlString: String

    @Environment(\.openURL) private var openURL

    private var resolvedURL: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: normalized)
    }

    var body: some View {
        // 轻点打开链接、长按复制 URL（粘到别处/分享）。
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "link")
                .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(labelKey))
                    .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
                // 中段截断：长链接保留首尾（域名 + 末段），比尾部截断更可读。
                Text(urlString)
                    .font(.system(.subheadline, design: .rounded)).foregroundStyle(CarryAccent.color)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture { if let resolvedURL { openURL(resolvedURL) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if let resolvedURL { openURL(resolvedURL) } }   // 旁白默认激活 = 打开
        .longPressCopy(urlString)                                             // 旁白「拷贝」动作 = 复制链接
    }
}

/// 备注行：图标 + 「备注」标签 + 可点击链接/电话的文本，长按整段复制（与其他可复制行一致）。
struct NoteDetailRow: View {
    let text: String
    @Environment(\.carryCopyToast) private var showToast

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "note.text")
                .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("itinerary.transport.field.note")
                    .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
                LinkAwareText(text: text, onLongPress: copyAll)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        // VoiceOver「拷贝」自定义动作（长按对旁白不可达，靠它兜底）。
        .accessibilityAction(named: Text("itinerary.detail.copy_action")) { copyAll() }
    }

    private func copyAll() {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showToast(NSLocalizedString("itinerary.stop.detail.address_copied", comment: ""))
    }
}

/// 可点击链接和电话号码的只读文本视图，支持长按全文复制回调。
/// - isSelectable = false：避免 UIKit 系统选择菜单与 Toast 复制冲突；data detector 点击不依赖 isSelectable。
/// - UILongPressGestureRecognizer：直接挂在 UITextView 上，SwiftUI .onLongPressGesture 无法穿透 UIKit 视图。
private struct LinkAwareText: UIViewRepresentable {
    let text: String
    var onLongPress: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = false   // 关闭选择：data detector 点击不受影响，长按由我们自己处理。
        tv.dataDetectorTypes = [.link, .phoneNumber]
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        tv.setContentHuggingPriority(.required, for: .vertical)
        // 水平方向不抵抗压缩：让父容器宽度约束 UITextView，而不是反过来被长文本撑宽 sheet。
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.isScrollEnabled = false

        let lp = UILongPressGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleLongPress(_:)))
        tv.addGestureRecognizer(lp)
        context.coordinator.textView = tv
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.onLongPress = onLongPress
        let uiFont = UIFont.preferredFont(forTextStyle: .subheadline)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: uiFont,
            .foregroundColor: UIColor.label,
        ]
        tv.attributedText = NSAttributedString(string: text, attributes: attrs)
        tv.tintColor = UIColor(CarryAccent.color)
    }

    class Coordinator: NSObject {
        var onLongPress: (() -> Void)?
        weak var textView: UITextView?

        @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began else { return }
            onLongPress?()
        }
    }
}

// MARK: - DetailActionFooter

/// 详情页底部动作收尾（替代整宽 Edit 大色块）：克制「✎ 编辑」胶囊 + 「···」菜单里的安静红「移除」。
/// 对标 Apple 日历事件详情底部（编辑 + 删除事件）——把动作降到配得上「编辑 + 移除」两动作的最轻 chrome：
/// 编辑是主动作、贴合内容宽的烟蓝胶囊（不再满宽大块）；移除藏在 ··· 菜单里、本就需「开菜单 → 点红字」两步，
/// 故**不再叠二次确认**（删单个实体低损失、可重加、菜单内不易误触）。
struct DetailActionFooter: View {
    let onEdit: () -> Void
    let onDelete: () -> Void
    /// nil = 不在 ··· 菜单里显示此项（CalendarEventDetailView 等不支持备注的场景传 nil）。
    var onNote: (() -> Void)? = nil
    /// nil = 不在 ··· 菜单里显示此项。
    var onCost: (() -> Void)? = nil
    /// 已有备注时菜单文案切为「编辑备注」。
    var hasNote: Bool = false
    /// 已有费用时菜单文案切为「编辑费用」。
    var hasCost: Bool = false

    var body: some View {
        // 两个**分离**的悬浮毛玻璃元件（编辑胶囊 + 独立的 ··· 圆，中间留空）——明确是两个按钮，不是「一个胶囊切两半」。
        // 由 DetailSheetScaffold 钉在底部、内容从身后滑过 → 毛玻璃实时模糊（对标 Tripsy 那排分离药丸/圆）。
        HStack(spacing: 10) {
            // 编辑 = 主操作，独立玻璃胶囊，占满左侧。
            Button(action: onEdit) {
                HStack(spacing: 7) {
                    Image(systemName: "pencil").font(.system(size: 15, weight: .semibold))
                    Text("itinerary.stop.detail.edit")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                }
                .foregroundStyle(CarryAccent.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(.thickMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                .compositingGroup()
                .shadow(color: Color.carryCardShadow, radius: 16, x: 0, y: 6)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("itinerary.stop.detail.edit"))

            // ··· = 独立玻璃圆（溢出菜单）。菜单恒向上展开；iOS 声明越靠前 = 越靠近锚点（底部）。
            // 顺序：移除（最前 = 最底，危险动作远离其它操作）；费用/备注居上（常用快捷）。
            Menu {
                Button(role: .destructive, action: onDelete) {
                    Label("common.remove", systemImage: "trash")
                }
                if onNote != nil || onCost != nil { Divider() }
                if let onNote {
                    Button(action: onNote) {
                        Label(hasNote ? "itinerary.menu.edit_note" : "itinerary.menu.add_note",
                              systemImage: "note.text")
                    }
                }
                if let onCost {
                    Button(action: onCost) {
                        Label(hasCost ? "itinerary.menu.edit_cost" : "itinerary.menu.record_cost",
                              systemImage: "creditcard")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 52)
                    .background(.thickMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                    .compositingGroup()
                    .shadow(color: Color.carryCardShadow, radius: 16, x: 0, y: 6)
                    .contentShape(Circle())
            }
            .accessibilityLabel(Text("common.more"))
        }
    }
}
