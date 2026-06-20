//
//  CostInputRow.swift
//  Carry
//
//  费用录入行（spec: itinerary-cost-tracking.md）。三处编辑页（地点 / 交通 / 住宿）共用。
//  金额输入 + 币种 chip（点开全屏可搜索选择器）。默认本位币、可改任意币种。
//

import SwiftUI

struct CostInputRow: View {
    /// 金额文本（父层 @State；空 = 未记录费用）。用字符串避免 Double 表达不了「空」。
    @Binding var amountText: String
    /// 选定币种（空 = 跟随本位币展示）。
    @Binding var currencyCode: String

    @AppStorage(ExchangeRateManager.preferredCurrencyDefaultsKey) private var preferredCurrencyRaw = ""
    @State private var showCurrencyPicker = false

    /// 显示层文本：编辑时＝规范无分组（光标不被逗号打断），失焦时＝带千分位。
    /// 绑定 `amountText` 永远只存规范值（父层 `parseAmount` 解析无歧义）。
    @State private var displayText = ""
    @FocusState private var amountFocused: Bool

    private var homeCode: String {
        preferredCurrencyRaw.isEmpty ? CurrencyCatalog.deviceDefaultCode : preferredCurrencyRaw.uppercased()
    }

    /// 实际生效币种：用户选过则用其选择，否则跟随本位币。
    private var effectiveCode: String {
        currencyCode.isEmpty ? homeCode : currencyCode.uppercased()
    }

    /// 非编辑态显示串：货币符号紧贴千分位金额（¥1,234.00）。符号并入文本本身（而非独立视图），
    /// 这样不存在「会被压缩的独立符号视图」——符号必随内容一起、永不被挤出；空金额则不显孤零符号。
    private func displayString(from canonical: String) -> String {
        let grouped = CurrencyCatalog.groupForDisplay(canonical)
        guard !grouped.isEmpty else { return "" }
        return CurrencyCatalog.symbol(for: effectiveCode) + grouped
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("cost.field.total")
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            // 金额输入框：非编辑态显示「符号 + 千分位」（见 displayString），编辑态显示纯数字。
            // 符号并入文本、不再是独立视图 → 长数字时不会被挤掉；位数有上限、显示串宽度天然有界。
            TextField("cost.amount.placeholder", text: $displayText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .rounded))
                .fixedSize()                       // 按内容定宽、整串完整显示，不留尾隙
                .focused($amountFocused)
            // 币种 = 带 chevron 的小菜单 chip，明确「可点换币种」（对标方案 A）。
            Button {
                showCurrencyPicker = true
            } label: {
                HStack(spacing: 3) {
                    Text(effectiveCode)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(CarryAccent.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(CarryAccent.color.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("cost.currency.title"))
        }
        // 编辑态：只收数字+单一小数点+≤2 位+整数位上限，挡住字母/粘贴/硬件键盘异常（根因解，写回规范值）。
        .onChange(of: displayText) { _, newValue in
            guard amountFocused else { return }          // 失焦时的程序化改写（带符号/分组）不在此净化
            let clean = CurrencyCatalog.sanitizeAmountInput(newValue)
            if clean != newValue { displayText = clean }
            amountText = clean                            // 绑定永远存规范无符号无分组值
        }
        // 进/出编辑：进＝纯数字便于改（去符号去分组），出＝符号+千分位展示。
        .onChange(of: amountFocused) { _, focused in
            displayText = focused
                ? CurrencyCatalog.sanitizeAmountInput(amountText)
                : displayString(from: amountText)
        }
        // 外部（父层 load 既有费用 / 清空）改了绑定且非编辑态 → 同步成符号+千分位展示。
        .onChange(of: amountText) { _, newValue in
            if !amountFocused { displayText = displayString(from: newValue) }
        }
        // 换币种 → 非编辑态刷新符号（符号现并入显示串，需主动重建）。
        .onChange(of: currencyCode) { _, _ in
            if !amountFocused { displayText = displayString(from: amountText) }
        }
        .onAppear { displayText = displayString(from: amountText) }
        .sheet(isPresented: $showCurrencyPicker) {
            NavigationStack {
                CurrencyPickerView(
                    onPick: { currencyCode = $0 },
                    selectedCode: effectiveCode
                )
            }
        }
    }
}
