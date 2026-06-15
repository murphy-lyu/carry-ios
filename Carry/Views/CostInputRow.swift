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
            TextField("cost.amount.placeholder", text: $amountText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .rounded))
                .frame(maxWidth: 130)
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
