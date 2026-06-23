//
//  CarryShortcuts.swift
//  Carry
//

import AppIntents
import SwiftData

// MARK: - Shared helpers

private extension UserDefaults {
    static let shortcutActionKey = "carry_shortcut_action"
    static let shortcutTripIdKey = "carry_shortcut_trip_id"
    static let shortcutFaceKey = "carry_shortcut_face"   // "itinerary" / "packing" / 缺省=上次脸
    static let shortcutDayKey = "carry_shortcut_day"     // dayOrder（仅行程脸今天锚点）

    /// Store a "navigate to existing trip" shortcut action（含目标脸 + 可选当天锚点，
    /// 由 `ContentView.handlePendingShortcut` 转成 `TripDeepLink` 走通知/Widget 同源路由）。
    func setShortcutOpenTrip(_ id: UUID, face: String? = nil, dayOrder: Int? = nil) {
        set("open_trip", forKey: Self.shortcutActionKey)
        set(id.uuidString, forKey: Self.shortcutTripIdKey)
        if let face { set(face, forKey: Self.shortcutFaceKey) } else { removeObject(forKey: Self.shortcutFaceKey) }
        if let dayOrder { set(dayOrder, forKey: Self.shortcutDayKey) } else { removeObject(forKey: Self.shortcutDayKey) }
    }

    /// Store a "create new trip" shortcut action.
    func setShortcutCreateTrip() {
        set("create_trip", forKey: Self.shortcutActionKey)
    }

    /// Store a "show footprint map" shortcut action.
    func setShortcutShowMap() {
        set("show_map", forKey: Self.shortcutActionKey)
    }
}

// MARK: - Home Screen Quick Actions

/// Bridges long-press home-screen Quick Actions into the same UserDefaults action
/// that `ContentView.handlePendingShortcut()` consumes. Quick Actions are a separate
/// system from AppShortcutsProvider (which only feeds Spotlight/Siri/Shortcuts), so
/// they must be wired explicitly via the scene delegate.
enum CarryQuickAction {
    static let newTrip     = "com.murphy.carry.quickaction.new_trip"
    static let nearestTrip = "com.murphy.carry.quickaction.nearest_trip"
    static let footprint   = "com.murphy.carry.quickaction.footprint"

    /// Translates a tapped quick action into the shared UserDefaults action.
    /// Writing the key triggers `UserDefaults.didChangeNotification`, which
    /// ContentView already observes to perform navigation — so no extra plumbing.
    static func handle(type: String) {
        let defaults = UserDefaults.standard
        switch type {
        case newTrip:
            defaults.setShortcutCreateTrip()
        case nearestTrip:
            if let target = QuickActionTarget.resolveFromStore() {
                defaults.setShortcutOpenTrip(target.tripId, face: target.faceRaw, dayOrder: target.dayOrder)
            } else {
                defaults.setShortcutCreateTrip()
            }
        case footprint:
            defaults.setShortcutShowMap()
        default:
            break
        }
    }
}

// MARK: - Quick Action 目标解析（相位感知，单一真源；spec: quick-actions-phase-aware.md）

enum QuickActionKind { case today, upcoming, recent }

/// 主屏中间槽 / Siri「最近行程」的目标，按相位：
/// - **today**（旅行中，`departureDate ≤ today ≤ returnDate`）→ 行程脸 + 今天锚点；
/// - **upcoming**（最近即将出发，`departureDate > today`）→ 打包脸；
/// - **recent**（无未来/进行中，回落最近过去行程供回看）→ 保持上次脸（`face == nil`）。
/// 未来/进行中优先级与 Widget 选片同口径（非无日期、`returnDate ≥ today`、出发日升序取首个）。
struct QuickActionTarget {
    let tripId: UUID
    let face: TripDetailFace?   // nil = 保持上次看的脸（.recent 回看用）
    let dayOrder: Int?          // 仅 .today：当天 dayOrder（0-based）
    let kind: QuickActionKind
    let city: String
    let dayNumber: Int          // 仅 .today：第几天（1-based，副标题用）
    let daysUntil: Int          // 仅 .upcoming：距出发天数（≥1，副标题用）

    var faceRaw: String? { face.map { $0 == .itinerary ? "itinerary" : "packing" } }

    static func resolve(trips: [TripBundle]) -> QuickActionTarget? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dated = trips.filter { !$0.isDateless }
        func city(_ t: TripBundle) -> String { t.destinationCity.isEmpty ? t.name : t.destinationCity }

        // 1. 未来/进行中（returnDate ≥ today，出发日升序取首个）。
        let upcomingOrActive = dated
            .filter { t in
                let ret = cal.date(byAdding: .day, value: t.days, to: t.departureDate) ?? t.departureDate
                return cal.startOfDay(for: ret) >= today
            }
            .min(by: { $0.departureDate < $1.departureDate })
        if let t = upcomingOrActive {
            let depDay = cal.startOfDay(for: t.departureDate)
            if today >= depDay {
                let span = max(1, t.days + 1)
                let idx = max(0, min(cal.dateComponents([.day], from: depDay, to: today).day ?? 0, span - 1))
                return QuickActionTarget(tripId: t.id, face: .itinerary, dayOrder: idx, kind: .today,
                                         city: city(t), dayNumber: idx + 1, daysUntil: 0)
            } else {
                let d = cal.dateComponents([.day], from: today, to: depDay).day ?? 0
                return QuickActionTarget(tripId: t.id, face: .packing, dayOrder: nil, kind: .upcoming,
                                         city: city(t), dayNumber: 0, daysUntil: max(1, d))
            }
        }

        // 2. 回落：最近的过去行程（供回看；保持上次脸）——保留旧 findNearestTrip 行为、不静默回归。
        if let t = dated.max(by: { $0.departureDate < $1.departureDate }) {
            return QuickActionTarget(tripId: t.id, face: nil, dayOrder: nil, kind: .recent,
                                     city: city(t), dayNumber: 0, daysUntil: 0)
        }
        return nil
    }

    /// 从库读全部行程后解析（scene delegate / App Intent 无 store 引用时用）。
    static func resolveFromStore() -> QuickActionTarget? {
        guard let trips = try? ModelContext(CarryApp.container).fetch(FetchDescriptor<TripBundle>()) else { return nil }
        return resolve(trips: trips)
    }
}

// MARK: - 1. New Trip

struct CreateTripIntent: AppIntent {
    static var title: LocalizedStringResource = "shortcut.create_trip.title"
    static var description = IntentDescription("shortcut.create_trip.description")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CarryLogger.shared.log(.siriShortcutExecuted, context: "action=create_trip")
        UserDefaults.standard.setShortcutCreateTrip()
        return .result()
    }
}

// MARK: - 2. Nearest Trip (by departure date)

struct OpenNearestTripIntent: AppIntent {
    static var title: LocalizedStringResource = "shortcut.nearest_trip.title"
    static var description = IntentDescription("shortcut.nearest_trip.description")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        if let target = QuickActionTarget.resolveFromStore() {
            CarryLogger.shared.log(.siriShortcutExecuted, context: "action=open_nearest_trip face=\(target.faceRaw ?? "last")")
            UserDefaults.standard.setShortcutOpenTrip(target.tripId, face: target.faceRaw, dayOrder: target.dayOrder)
        } else {
            CarryLogger.shared.log(.siriShortcutExecuted, context: "action=open_nearest_trip fallback=create")
            UserDefaults.standard.setShortcutCreateTrip()
        }
        return .result()
    }
}

// MARK: - 3. Footprint — open the visited-countries map

struct ShowFootprintIntent: AppIntent {
    static var title: LocalizedStringResource = "shortcut.footprint.title"
    static var description = IntentDescription("shortcut.footprint.description")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CarryLogger.shared.log(.siriShortcutExecuted, context: "action=show_footprint")
        UserDefaults.standard.set("show_map", forKey: "carry_shortcut_action")
        return .result()
    }
}

// MARK: - App Shortcuts Provider

struct CarryAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateTripIntent(),
            phrases: [
                "New trip in \(.applicationName)",
                "Create a trip in \(.applicationName)",
                "Plan a trip with \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("New Trip"),
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: OpenNearestTripIntent(),
            phrases: [
                "My next trip in \(.applicationName)",
                "Upcoming trip in \(.applicationName)",
                "Open my trip in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("Nearest Trip"),
            systemImageName: "suitcase"
        )
        AppShortcut(
            intent: ShowFootprintIntent(),
            phrases: [
                "Show my footprint in \(.applicationName)",
                "Open travel map in \(.applicationName)",
                "My visited countries in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("Footprint"),
            systemImageName: "globe.asia.australia"
        )
    }
}
