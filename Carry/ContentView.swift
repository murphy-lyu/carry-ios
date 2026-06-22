//
//  ContentView.swift
//  Carry
//

import SwiftUI
import Combine

// MARK: - Creation Route

enum CreationRoute: Hashable {
    case tripInfo(UUID)
    case packingList(UUID)
    case autoPackPicker(TripInfo, sceneKeys: [String])
}

// MARK: - Deep-link Target

/// 行程详情页的两张脸（spec: notification-deeplink-routing.md / itinerary-route-planning.md）。
/// 提升为共享类型，使通知/深链跳转能按语义选脸（`PackingListView` 与路由共用一套）。
enum TripDetailFace: Equatable { case packing, itinerary }

/// 行程脸内的锚点：跳转后定位到对应「天」并滚动到位。
enum TripDeepLinkAnchor: Equatable {
    case day(Int)         // dayOrder
    case segment(UUID)    // 交通段 id → 其所在天
    case lodging(UUID)    // 住宿 id → 退房天
}

/// 通知/Widget/URL/快捷指令唤起某行程时的富目标（spec: notification-deeplink-routing.md）。
/// `face == nil` = 保持该行程「上次看的脸」（Widget / carry://trip / 快捷指令）。
struct TripDeepLink: Equatable {
    let tripId: UUID
    var face: TripDetailFace? = nil
    var anchor: TripDeepLinkAnchor? = nil
}

// MARK: - Navigation Router

final class NavigationRouter: ObservableObject {
    @Published var path = NavigationPath()
    @Published var showMapFullscreen = false

    /// 待唤起的行程深链（通知/Widget/URL/快捷指令）。承接侧 `handlePendingTrip` 消费：
    /// 选脸 + 拆 modal + 落 path + 写锚点。spec: notification-deeplink-routing.md。
    @Published var pendingTrip: TripDeepLink? = nil

    /// 行程脸待消费的锚点。ItineraryView 数据就绪后读取一次、定位到对应天，然后清空。
    @Published var pendingItineraryAnchor: TripDeepLinkAnchor? = nil

    /// 深链（通知/Widget/快捷指令）唤起行程时递增。行程详情是 push 进根 NavigationStack 的，而
    /// 根级 modal（Settings/Search/Trip Book…）盖在栈之上、push 不会自动关它 → 详情被挡住看不到。
    /// HomeView 观察此信号、关掉自己那几个根级 sheet，让被 push 的详情真正露出来。
    @Published var rootModalDismissalRequest = 0

    // 同行者发来的 .carrytrip 文件（点开后由 CarryApp.onOpenURL 读取摘要写入），
    // ContentView 观察它弹出「导入行程」确认。
    @Published var pendingSharedTrip: DataBackupManager.SharedTripSummary? = nil

    // 创建行程是「自包含任务」而非根层级——iPhone 用独立的 sheet（自有 NavigationStack）承载，
    // 不污染根 path；完成后关 sheet、把根 path 落到新行程。现已是单屏：TripInfoView 填完「Create」
    // 直接建行程并落到该行程（早期 TripInfo → ItemPicker → PackingList 多步流已简化掉）。
    // creationPath / pushCreation 仍保留，供 Mac 端（无 sheet、退回根 path 推进）复用同一套创建代码。
    // （spec: app-navigation-framework.md）
    @Published var showCreation = false
    @Published var creationPath = NavigationPath()
    @Published var creationSeed: CreationSeed? = nil

    struct CreationSeed: Equatable { let id: UUID }

    /// 打开创建 cover（iPhone）。每次重置 creationPath，从 TripInfoView 起步。
    func beginCreation() {
        creationSeed = CreationSeed(id: UUID())
        creationPath = NavigationPath()
        showCreation = true
    }

    /// 创建流内前进一步。iPhone（cover 开着）压 creationPath；Mac（无 cover）退回根 path 推进。
    /// 让 TripInfoView / ItemPickerView 共用一套代码、不必到处 `#if`。
    func pushCreation(_ route: CreationRoute) {
        if showCreation { creationPath.append(route) } else { path.append(route) }
    }

    /// 创建完成：关 cover、清空创建栈，根 path 落到新行程（保留「建完即进入行程」的动量）。
    /// Mac 无 cover 时 showCreation 本就 false，等价于旧行为 `path = [id]`（弹掉创建步、进入行程）。
    func finishCreation(landingTripId: UUID) {
        path = NavigationPath([landingTripId])
        creationPath = NavigationPath()
        creationSeed = nil
        showCreation = false
    }

    /// 放弃创建：关 cover、清空创建栈，不建任何行程。
    func cancelCreation() {
        creationPath = NavigationPath()
        creationSeed = nil
        showCreation = false
    }
}

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var router: NavigationRouter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    // Mac Catalyst 的设置 sheet 仍用此路径；iPhone 设置已迁入 HomeView 自管（spec: app-navigation-framework.md）。
    @State private var settingsPath = NavigationPath()
    @State private var didApplyStartupReset = false
    @State private var didRefreshOnLaunch = false
    @State private var showSettingsOnMac = false
    // 同 HomeView：sheet 独立呈现，需自带 preferredColorScheme，否则在设置页内切外观不立即生效。
    @AppStorage("appearance_mode") private var appearanceModeRaw = AppearanceMode.system.rawValue

    var body: some View {
        #if targetEnvironment(macCatalyst)
        macLayout
        #else
        iPhoneLayout
        #endif
    }

    // MARK: - Mac layout

    #if targetEnvironment(macCatalyst)
    @ViewBuilder
    private var macLayout: some View {
        ZStack(alignment: .leading) {
            // Globe fills the entire window background
            MacGlobePanel()
                .ignoresSafeArea()

            // Left panel floats over the globe as a card with breathing room
            NavigationStack(path: $router.path) {
                HomeView()
                    .navigationDestination(for: UUID.self) { id in
                        PackingListView(tripId: id)
                    }
                    .navigationDestination(for: CreationRoute.self) { route in
                        routeDestination(route)
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { showSettingsOnMac = true } label: {
                                Image(systemName: "gear")
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
            }
            .frame(width: 360)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(colorScheme == .dark
                        ? Color(red: 0.09, green: 0.09, blue: 0.10)
                        : Color(UIColor.systemBackground))
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 32, x: 0, y: 8)
            .padding(.leading, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .sheet(isPresented: $showSettingsOnMac) {
                NavigationStack(path: $settingsPath) { SettingsView(path: $settingsPath) }
                    .frame(minWidth: 420, minHeight: 560)
                    .preferredColorScheme((AppearanceMode(rawValue: appearanceModeRaw) ?? .system).colorScheme)
            }
        }
        .tint(CarryAccent.color)
        .environmentObject(store)
        .environmentObject(router)
        .onAppear { onAppearCommon() }
        .onChange(of: router.pendingTrip) { _, link in handlePendingTrip(link) }
        .onChange(of: scenePhase) { _, phase in onScenePhaseChange(phase) }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            if didApplyStartupReset { handlePendingShortcut() }
        }
    }
    #endif

    // MARK: - iPhone layout

    @ViewBuilder
    private var iPhoneLayout: some View {
        // 根级不再是 TabView：根就是行程首页（足迹地球 + Sheet）。设置迁入 HomeView 右上入口，
        // 创建迁到 HomeView 右下悬浮。（spec: app-navigation-framework.md）
        NavigationStack(path: $router.path) {
            HomeView()
                .navigationDestination(for: UUID.self) { id in
                    PackingListView(tripId: id)
                }
                .navigationDestination(for: CreationRoute.self) { route in
                    routeDestination(route)
                }
        }
        // 创建行程：以 sheet（page sheet）模态呈现——单屏轻任务，卡片圆角与系统协调、露出背后的
        // 行程列表，符合 Apple「快速创建表单」范式（新建事件/提醒/联系人同款）。旧 fullScreenCover 是
        // 为早期多步流程准备的，流程简化为单屏后既不符合 HIG、其方角内容又会撞上屏幕物理圆角、显得不协调。
        // 内含 NavigationStack 承载标题与「取消」。
        .sheet(isPresented: $router.showCreation) {
            if let seed = router.creationSeed {
                NavigationStack(path: $router.creationPath) {
                    TripInfoView(routeID: seed.id)
                        .navigationDestination(for: CreationRoute.self) { route in
                            routeDestination(route)
                        }
                }
                .tint(CarryAccent.color)
                .preferredColorScheme((AppearanceMode(rawValue: appearanceModeRaw) ?? .system).colorScheme)
                // 与设置 / 搜索 / Trip Book 三个 sheet 一致：弹出时首页后退缩放、跟手拖拽。
                #if !targetEnvironment(macCatalyst)
                .background(PresenterRecedeEffect())
                #endif
            }
        }
        // 同行者发来的 .carrytrip 文件：弹「导入行程」确认卡片。
        .sheet(item: $router.pendingSharedTrip) { summary in
            ImportSharedTripSheet(summary: summary)
                .tint(CarryAccent.color)
                .preferredColorScheme((AppearanceMode(rawValue: appearanceModeRaw) ?? .system).colorScheme)
        }
        .tint(CarryAccent.color)
        .environmentObject(store)
        .environmentObject(router)
        .onAppear { onAppearCommon() }
        .onChange(of: router.pendingTrip) { _, link in handlePendingTrip(link) }
        .onChange(of: scenePhase) { _, phase in onScenePhaseChange(phase) }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            if didApplyStartupReset { handlePendingShortcut() }
        }
    }

    // MARK: - Shared helpers

    @ViewBuilder
    private func routeDestination(_ route: CreationRoute) -> some View {
        switch route {
        case .tripInfo(let routeID):
            TripInfoView(routeID: routeID)
        case .packingList(let id):
            PackingListView(tripId: id, isNewTrip: true)
        case .autoPackPicker(let info, let sceneKeys):
            ItemPickerView(
                autoPackTripInfo: info,
                sceneKeys: sceneKeys,
                isInternational: store.inferIsInternational(for: info.destinationCity),
                destinationCodes: store.inferCountryCodes(for: info.destinationCity)
            )
            .id(sceneKeys.sorted().joined(separator: ","))
        }
    }

    private func onAppearCommon() {
        applyStartupResetIfNeeded()
        if !didRefreshOnLaunch {
            didRefreshOnLaunch = true
            store.refresh()
        }
        // 深链冷启动保护：CarryApp.onOpenURL 在 SplashView 阶段就可能把 pendingTrip
        // 设上（Widget/通知/Universal Link 冷启动），那时 ContentView 还没 mount，
        // onChange(of: pendingTrip) 不会重放历史值——直接丢失。这里主动消费一次。
        // 见 memory project_carry_deeplink_timing.md。
        if let link = router.pendingTrip {
            handlePendingTrip(link)
        }
    }

    /// 承接通知/Widget/URL/快捷指令的行程深链（spec: notification-deeplink-routing.md）：
    /// ① 按语义选脸（无闪烁：跳转前写 TripDetailFaceStore，PackingListView.init 首帧即读到）；
    /// ② 拆掉盖在根导航栈上的 modal；③ 落 path；④ 写锚点供 ItineraryView 滚到对应天。
    private func handlePendingTrip(_ link: TripDeepLink?) {
        guard let link else { return }
        // ① 选脸（face==nil 表示保持上次脸——Widget / carry://trip / 快捷指令）。
        if let face = link.face { TripDetailFaceStore.save(face, tripId: link.tripId) }
        // ② 拆 modal：用户停在 Settings/创建/分享导入… 按 Home 退出、收到通知点进来时，
        // 只 push 底层栈会被 sheet 挡住。ContentView 级直接置空，HomeView 级经信号自关。
        router.showCreation = false
        router.pendingSharedTrip = nil
        showSettingsOnMac = false
        router.rootModalDismissalRequest &+= 1
        // ③ 落 path（行程详情页内的 sheet 随 path 重置一并卸载，无需单独处理）。
        router.path = NavigationPath()
        router.path.append(link.tripId)
        // ④ 锚点交给 ItineraryView 就绪后消费（仅行程脸有锚点）。
        router.pendingItineraryAnchor = link.anchor
        router.pendingTrip = nil
    }

    private func onScenePhaseChange(_ phase: ScenePhase) {
        if phase == .active {
            applyStartupResetIfNeeded()
            store.refresh()
            if didApplyStartupReset { handlePendingShortcut() }
        }
    }

    private func applyStartupResetIfNeeded() {
        guard !didApplyStartupReset else { return }
        // Prevent iOS state restoration from reopening stale navigation/sheet routes.
        router.path = NavigationPath()
        didApplyStartupReset = true
        // Handle any Spotlight / Siri shortcut that launched the app.
        handlePendingShortcut()
    }

    /// Reads a pending shortcut action written by a CarryAppIntent and navigates accordingly.
    /// Safe to call multiple times — clears UserDefaults immediately so it's a no-op on repeat.
    func handlePendingShortcut() {
        let defaults = UserDefaults.standard
        guard let action = defaults.string(forKey: "carry_shortcut_action") else { return }
        defaults.removeObject(forKey: "carry_shortcut_action")

        // ⚠️ asyncAfter 反模式（CLAUDE.md 点名），但此处保留：SplashView 淡出 + ContentView
        // 完全 attach + NavigationStack ready 三者的"就绪事件"在 SwiftUI 里没有可观察的钩子。
        // 改为 0 ms 立即 push 在老机型/慢启动场景下会让 NavigationStack 错过这次 push。
        // 真正消除此延迟需重构为"路径就绪通知 → 消费 pending"——超出本次 QA 修复范围。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            switch action {
            case "create_trip":
                #if targetEnvironment(macCatalyst)
                router.path.append(CreationRoute.tripInfo(UUID()))
                #else
                router.beginCreation()
                #endif
            case "open_trip":
                if let idStr = defaults.string(forKey: "carry_shortcut_trip_id"),
                   let id = UUID(uuidString: idStr) {
                    defaults.removeObject(forKey: "carry_shortcut_trip_id")
                    router.path.append(id)
                }
            case "show_map":
                router.path = NavigationPath()   // go to HomeView root
                router.showMapFullscreen = true  // signal HomeView to collapse sheet
            default:
                break
            }
        }
    }
}
