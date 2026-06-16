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
            // 货币符号紧贴金额（¥ 1000）：即时识别币种、更专业。符号取生效币种、secondary 不抢数字。
            HStack(spacing: 3) {
                Text(CurrencyCatalog.symbol(for: effectiveCode))
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                TextField("cost.amount.placeholder", text: $amountText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .rounded))
                    .fixedSize()                       // 贴着符号、按内容定宽，不留尾隙
                    // 数据层净化：只收数字+单一小数点+≤2 位；挡住字母/粘贴/硬件键盘异常输入（根因解）。
                    .onChange(of: amountText) { _, newValue in
                        let clean = CurrencyCatalog.sanitizeAmountInput(newValue)
                        if clean != newValue { amountText = clean }
                    }
            }
            .frame(maxWidth: 160, alignment: .trailing)
            Button {
                showCurrencyPicker = true
            } label: {
                Text(effectiveCode)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(CarryAccent.color)
                    .frame(minWidth: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("cost.currency.title"))
        }
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
