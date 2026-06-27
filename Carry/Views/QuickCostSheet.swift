//
//  QuickCostSheet.swift
//  Carry
//
//  ··· 菜单「记录费用」快捷入口的轻量 sheet。大金额显示 + numpad + 货币选择。
//

import SwiftUI

struct QuickCostSheet: View {
    /// 现有金额（0 = 未记录）。
    let existingAmount: Double
    /// 现有货币码（空 = 跟随本位币）。
    let existingCurrencyCode: String
    /// 保存回调（amount=0 且 code="" → 清除）。
    let onSave: (Double, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(ExchangeRateManager.preferredCurrencyDefaultsKey) private var preferredCurrencyRaw = ""

    @State private var amountText: String = ""
    @State private var currencyCode: String = ""
    @State private var showCurrencyPicker = false
    @FocusState private var numpadFocused: Bool

    private var homeCode: String {
        preferredCurrencyRaw.isEmpty ? CurrencyCatalog.deviceDefaultCode : preferredCurrencyRaw.uppercased()
    }

    private var effectiveCode: String {
        currencyCode.isEmpty ? homeCode : currencyCode.uppercased()
    }

    /// 大数字显示串：有输入时带货币符号和千分位，空时显「0」。
    private var displayAmount: String {
        guard !amountText.isEmpty else { return "0" }
        let sym = CurrencyCatalog.symbol(for: effectiveCode)
        let grouped = CurrencyCatalog.groupForDisplay(amountText)
        return grouped.isEmpty ? "0" : sym + grouped
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                // 大金额显示区
                Text(displayAmount)
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .foregroundStyle(amountText.isEmpty ? .tertiary : .primary)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, 32)
                    .animation(.easeInOut(duration: 0.1), value: amountText)

                Spacer().frame(height: 28)

                // 货币选择胶囊
                Button {
                    showCurrencyPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Text(effectiveCode)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(CarryAccent.color)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(CarryAccent.color.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("cost.currency.title"))

                Spacer()

                // 隐藏 TextField 仅用于调起 numpad
                TextField("", text: $amountText)
                    .keyboardType(.decimalPad)
                    .focused($numpadFocused)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                    .onChange(of: amountText) { _, newValue in
                        let clean = CurrencyCatalog.sanitizeAmountInput(newValue)
                        if clean != newValue { amountText = clean }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { numpadFocused = true }
            .navigationTitle(Text("quickaction.cost.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        Text("quickaction.cost.done")
                            .fontWeight(.semibold)
                    }
                }
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
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear {
            amountText = existingAmount > 0 ? CurrencyCatalog.amountText(existingAmount) : ""
            currencyCode = existingCurrencyCode
            // 延迟一帧再 focus，保证 sheet present 动画完成后键盘再弹出。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                numpadFocused = true
            }
        }
        .onDisappear { commitSave() }
    }

    private func save() {
        numpadFocused = false
        dismiss()
    }

    private func commitSave() {
        let amount = CurrencyCatalog.parseAmount(amountText)
        let code: String
        if amountText.trimmingCharacters(in: .whitespaces).isEmpty {
            code = ""
        } else {
            code = currencyCode.isEmpty ? homeCode : currencyCode.uppercased()
        }
        onSave(amount, code)
    }
}
