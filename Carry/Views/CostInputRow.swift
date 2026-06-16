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

    var body: some View {
        HStack(spacing: 12) {
            Text("cost.field.label")
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            // 货币符号紧贴金额（¥ 1,234.00）：即时识别币种、更专业。符号取生效币种、secondary 不抢数字。
            HStack(spacing: 3) {
                Text(CurrencyCatalog.symbol(for: effectiveCode))
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                TextField("cost.amount.placeholder", text: $displayText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .rounded))
                    .fixedSize()                       // 贴着符号、按内容定宽，不留尾隙
                    .focused($amountFocused)
            }
            .frame(maxWidth: 160, alignment: .trailing)
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
        // 编辑态：只收数字+单一小数点+≤2 位，挡住字母/粘贴/硬件键盘异常（根因解，写回规范值）。
        .onChange(of: displayText) { _, newValue in
            guard amountFocused else { return }          // 失焦时的程序化分组改写不在此净化
            let clean = CurrencyCatalog.sanitizeAmountInput(newValue)
            if clean != newValue { displayText = clean }
            amountText = clean                            // 绑定永远存规范无分组值
        }
        // 进/出编辑：进＝去分组便于改，出＝加千分位展示。
        .onChange(of: amountFocused) { _, focused in
            displayText = focused
                ? CurrencyCatalog.sanitizeAmountInput(displayText)
                : CurrencyCatalog.groupForDisplay(displayText)
        }
        // 外部（父层 load 既有费用 / 清空）改了绑定且非编辑态 → 同步成带千分位展示。
        .onChange(of: amountText) { _, newValue in
            if !amountFocused { displayText = CurrencyCatalog.groupForDisplay(newValue) }
        }
        .onAppear { displayText = CurrencyCatalog.groupForDisplay(amountText) }
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
