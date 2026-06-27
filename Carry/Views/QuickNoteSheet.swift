//
//  QuickNoteSheet.swift
//  Carry
//
//  ··· 菜单「添加备注」快捷入口的轻量 sheet。dismiss 即保存（iOS Notes 范式，无 Cancel）。
//

import SwiftUI

struct QuickNoteSheet: View {
    /// 当前已有的备注文本（预填）。
    let existingNote: String
    /// 保存回调，传入新备注文本（空字符串 = 清除备注）。
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .focused($focused)
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .scrollContentBackground(.hidden)

                // TextEditor 无内置 placeholder，用 overlay 模拟。
                if text.isEmpty {
                    Text("quickaction.note.placeholder")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 21)
                        .padding(.top, 16)
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle(Text("quickaction.note.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        Text("quickaction.note.done")
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            text = existingNote
            focused = true
        }
        // dismiss（下滑）也触发保存，与点「完成」语义一致。
        .interactiveDismissDisabled(false)
        .onDisappear { onSave(text) }
    }

    private func save() {
        focused = false
        dismiss()
        // onDisappear 会再次调 onSave，但 TripStore 的 updateXxx 是幂等的，重复调用无副作用。
    }
}
