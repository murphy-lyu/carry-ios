//
//  CarryLogger.swift
//  Carry
//

import UIKit

final class CarryLogger {
    static let shared = CarryLogger()

    private let maxEntries = 500
    private let storageKey = "carry_event_log"
    private let versionKey = "carry_log_version"
    private let retentionDays = 30

    enum Event: String {
        // 行程
        case tripCreated            = "trip_created"
        case tripDeleted            = "trip_deleted"
        case tripDuplicated         = "trip_duplicated"
        case tripOpened             = "trip_opened"
        case tripInfoOpened         = "trip_info_opened"
        case tripEditSaved          = "trip_edit_saved"
        case tripEditCancelled      = "trip_edit_cancelled"
        case tripCompleted          = "trip_completed"
        case tripUncompleted        = "trip_uncompleted"
        // 分类
        case sectionAdded           = "section_added"
        case sectionDeleted         = "section_deleted"
        case sectionRenamed         = "section_renamed"
        // My Items
        case myItemAdded            = "my_item_added"
        case myItemDeleted          = "my_item_deleted"
        // 惊喜 / 场景卡片
        case surpriseItemAdded      = "surprise_item_added"
        case surpriseItemDismissed  = "surprise_item_dismissed"
        case sceneCardDismissed     = "scene_card_dismissed"
        // 提醒
        case reminderAdded          = "reminder_added"
        case reminderDeleted        = "reminder_deleted"
        case reminderPermissionDenied = "reminder_permission_denied"
        // 应用图标
        case iconSwitched           = "icon_switched"
        case iconSwitchFailed       = "icon_switch_failed"
        // 数据备份 / 恢复
        case backupExported         = "backup_exported"
        case backupRestored         = "backup_restored"
        case backupRestoreFailed    = "backup_restore_failed"
        // 物品选择器
        case pickerOpened           = "picker_opened"
        case pickerCategoryExpanded = "picker_category_expanded"
        case pickerSearchUsed       = "picker_search_used"
        case pickerSourceSwitched   = "picker_source_switched"
        case pickerSelectAllTapped  = "picker_select_all_tapped"
        case pickerConfirmed        = "picker_confirmed"
        // 物品
        case itemChecked            = "item_checked"
        case itemUnchecked          = "item_unchecked"
        case itemAdded              = "item_added"
        case itemDeleted            = "item_deleted"
        // Auto Pack / 场景
        case autoPackTriggered          = "auto_pack_triggered"
        case autoPackNavigationFailed   = "auto_pack_nav_failed"
        case sectionReordered           = "section_reordered"
        // 生命周期
        case appLaunched            = "app_launched"
        case appDidEnterBackground  = "app_did_enter_background"
        case appWillEnterForeground = "app_will_enter_foreground"
        case appWillTerminate       = "app_will_terminate"
        case memoryWarning          = "memory_warning"
        // 保存失败
        case tripSaveFailed         = "trip_save_failed"
        case tripEditSaveFailed     = "trip_edit_save_failed"
        case itemAddFailed          = "item_add_failed"
        case itemDeleteFailed       = "item_delete_failed"
        case persistFailed          = "persist_failed"
        case reorderSaveFailed      = "reorder_save_failed"
        // 数据一致性
        case dataCorrupted          = "data_corrupted"
        case orphanTrip             = "orphan_trip"
        case orphanSection          = "orphan_section"
        case sortIndexOutOfBounds   = "sort_index_out_of_bounds"
        case tripDataEmpty          = "trip_data_empty"
        // 初始化
        case dbInitFailed           = "db_init_failed"
        case duplicateFailed        = "duplicate_failed"
        case loadFailed             = "load_failed"
        // 网络（为后续 AI 功能预留）
        case apiTimeout             = "api_timeout"
        case apiError               = "api_error"
    }

    private static let errorEvents: Set<Event> = [
        .persistFailed, .loadFailed, .dbInitFailed, .dataCorrupted,
        .duplicateFailed, .reorderSaveFailed, .autoPackNavigationFailed,
        .tripDataEmpty, .tripSaveFailed, .tripEditSaveFailed,
        .itemAddFailed, .itemDeleteFailed, .orphanTrip, .orphanSection,
        .sortIndexOutOfBounds, .apiTimeout, .apiError,
        .iconSwitchFailed, .backupRestoreFailed, .reminderPermissionDenied,
    ]

    private init() {
        performVersionCleanup()
        performTimeCleanup()
    }

    // MARK: - Public

    func log(_ event: Event, context: String? = nil) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let isError = Self.errorEvents.contains(event)
        var entry = "[\(timestamp)] [\(isError ? "ERROR" : "ACTION")] \(event.rawValue)"
        if let context { entry += " \(context)" }

        var entries = loadEntries()
        entries.append(entry)
        if entries.count > maxEntries {
            entries = Array(entries.suffix(maxEntries))
        }
        saveEntries(entries)
    }

    func exportLog(tripCount: Int, totalItemCount: Int) -> String {
        let device = UIDevice.current
        let dict = Bundle.main.infoDictionary
        let appVersion = dict?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = dict?["CFBundleVersion"] as? String ?? "?"
        let generated = ISO8601DateFormatter().string(from: Date())

        var output = """
        ===== Carry Debug Log =====
        Generated: \(generated)
        App Version: \(appVersion) (\(buildNumber))
        Device: \(device.model)
        OS: \(device.systemName) \(device.systemVersion)
        Trip count: \(tripCount)
        Total items across all trips: \(totalItemCount)
        ===========================

        """
        output += loadEntries().joined(separator: "\n")
        return output
    }

    // MARK: - Cleanup

    private func performVersionCleanup() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let stored = UserDefaults.standard.string(forKey: versionKey)
        guard stored != current else { return }
        saveEntries([])
        UserDefaults.standard.set(current, forKey: versionKey)
    }

    private func performTimeCleanup() {
        let formatter = ISO8601DateFormatter()
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        let filtered = loadEntries().filter { entry in
            guard entry.hasPrefix("["),
                  let closing = entry.firstIndex(of: "]")
            else { return true }
            let tsRange = entry.index(after: entry.startIndex)..<closing
            guard let date = formatter.date(from: String(entry[tsRange])) else { return true }
            return date >= cutoff
        }
        saveEntries(filtered)
    }

    // MARK: - Storage

    private func loadEntries() -> [String] {
        (UserDefaults.standard.array(forKey: storageKey) as? [String]) ?? []
    }

    private func saveEntries(_ entries: [String]) {
        UserDefaults.standard.set(entries, forKey: storageKey)
    }
}
