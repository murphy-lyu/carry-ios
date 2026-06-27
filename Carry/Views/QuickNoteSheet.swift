//
//  QuickNoteSheet.swift
//  Carry
//
//  ··· 菜单「添加备注」快捷入口的轻量 sheet。完成保存，取消/下滑放弃。
//

import SwiftUI

struct QuickNoteSheet: View {
    let existingNote: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var cancelled = false
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
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("common.cancel")) {
                        cancelled = true
                        dismiss()
                    }
                }
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
        .onDisappear {
            // 下滑关闭 = 放弃（不保存）；只有点「完成」才保存。
            guard !cancelled else { return }
            onSave(text)
        }
    }

    private func save() {
        focused = false
        onSave(text)
        cancelled = true   // 标记已显式保存，onDisappear 不重复调用。
        dismiss()
    }
}
