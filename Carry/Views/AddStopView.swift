//
//  AddStopView.swift
//  Carry
//
//  添加停靠点：地理搜索（MKLocalSearchCompleter 边输边补全）选 POI 入库，
//  或手动输名添加「无坐标停靠点」。spec: itinerary-route-planning.md。
//

import SwiftUI
import MapKit
import Combine

// MARK: - 统一地点检索（高德 + 海外 Mapbox 双源 · spec: itinerary-overseas-poi-search.md）

/// 搜索候选——统一两源:MapKit/高德(国内) 与 海外 places Worker(Mapbox)。
struct PlaceSuggestion: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let kind: Kind
    enum Kind {
        case mapkit(MKLocalSearchCompletion)   // 选中走 MKLocalSearch 解析
        case overseas(mapboxId: String)        // 选中走 places Worker /retrieve
    }
}

/// 解析后的地点(两源殊途同归 → 同一下游入库/回填)。
struct ResolvedPlace {
    let name: String
    let latitude: Double
    let longitude: Double
    let address: String
    let phone: String
    let timeZoneId: String
    /// 权威 ISO 国家码（alpha-2，大写；可能为空）。MapKit 取 placemark.isoCountryCode、
    /// 海外走 Worker 回传的 country。供「输入即解析」主目的地直接点亮地图，免文本反解析。
    /// 默认空：现有 stop 入库流程不读此字段，不受影响。
    var countryCode: String = ""
}

/// 海外检索代理配置(places Worker)。token 从 gitignore 的 Secrets.plist 读(同航班范式)。
enum PlacesSearchConfig {
    static let baseURL = "https://places.nevestudio.app"
    static let appToken: String = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url),
              let t = dict["PlacesProxyAppToken"] as? String else { return "" }
        return t
    }()
    static var isConfigured: Bool { !appToken.isEmpty }
}

/// 海外地点检索(经 places Worker:Mapbox 代理 + 缓存 + 翻译 + 坐标转时区 + 只回境外)。
enum OverseasPlaceSource {
    static func suggest(query: String, proximity: String, session: String, storefront: String, placeMode: Bool = false) async -> [PlaceSuggestion] {
        guard PlacesSearchConfig.isConfigured, !query.isEmpty,
              var comps = URLComponents(string: PlacesSearchConfig.baseURL + "/suggest") else { return [] }
        comps.queryItems = [.init(name: "q", value: query), .init(name: "session", value: session),
                            .init(name: "storefront", value: storefront)]
        if !proximity.isEmpty { comps.queryItems?.append(.init(name: "proximity", value: proximity)) }
        // 城市模式（建行程·目的地字段）：只查行政地名，让 Worker 切换 types。缺省走全量 POI。
        // 并把 UI 语言传给 Worker 做本地化检索——否则 München/Roma/Lisboa 等本地异名在 language=en 下匹配不到城市本体。
        if placeMode {
            comps.queryItems?.append(.init(name: "kinds", value: "place"))
            let uiLang = Bundle.main.preferredLocalizations.first ?? "en"
            comps.queryItems?.append(.init(name: "lang", value: uiLang))
        }
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        req.setValue(PlacesSearchConfig.appToken, forHTTPHeaderField: "X-App-Token")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SuggestResponse.self, from: data) else { return [] }
        return decoded.suggestions.map {
            PlaceSuggestion(id: "ov:\($0.id)", title: $0.name, subtitle: $0.secondary ?? "", kind: .overseas(mapboxId: $0.id))
        }
    }

    static func retrieve(mapboxId: String, session: String, storefront: String) async -> ResolvedPlace? {
        guard PlacesSearchConfig.isConfigured,
              var comps = URLComponents(string: PlacesSearchConfig.baseURL + "/retrieve") else { return nil }
        comps.queryItems = [.init(name: "id", value: mapboxId), .init(name: "session", value: session),
                            .init(name: "storefront", value: storefront)]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        req.setValue(PlacesSearchConfig.appToken, forHTTPHeaderField: "X-App-Token")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(RetrieveResponse.self, from: data) else { return nil }
        let p = decoded.place
        return ResolvedPlace(name: p.name, latitude: p.latitude, longitude: p.longitude,
                             address: p.address, phone: p.phone ?? "", timeZoneId: p.timeZoneId ?? "",
                             countryCode: (p.country ?? "").uppercased())
    }

    private struct SuggestResponse: Decodable { let suggestions: [Item]; struct Item: Decodable { let id: String; let name: String; let secondary: String? } }
    // country 为后加字段：旧 Worker（未部署 country 透传）不返回 → 可选解码为 nil，向后兼容。
    private struct RetrieveResponse: Decodable { let place: Place; struct Place: Decodable { let name: String; let latitude: Double; let longitude: Double; let address: String; let phone: String?; let timeZoneId: String?; let country: String? } }
}

/// 统一补全器:MapKit/高德(国内) + 海外 Mapbox(经 Worker),合并发布;选中按来源分流解析。
@MainActor
final class StopSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query: String = "" {
        didSet { completer.queryFragment = query; scheduleOverseas() }
    }
    @Published var results: [PlaceSuggestion] = []

    /// 城市模式：给「建行程·目的地」字段用——只补全行政地名（国家/地区/城市），不掺 POI。
    /// 切 MapKit `resultTypes`（去 .pointOfInterest）+ 让海外路传 `kinds=place` 给 Worker。
    /// 默认 false（AddStop 的地点检索仍要 POI）。
    var placeMode = false {
        didSet { completer.resultTypes = placeMode ? [.address] : [.pointOfInterest, .address] }
    }

    private let completer = MKLocalSearchCompleter()
    private var mapkitResults: [PlaceSuggestion] = []
    private var overseasResults: [PlaceSuggestion] = []
    private var proximity = ""                 // "lon,lat"
    private var session = UUID().uuidString    // Mapbox Search Box 会话（按 session 计费：N×suggest + 1×retrieve = 1 次搜索；retrieve 后轮换）
    private var overseasTask: Task<Void, Never>?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    /// 用行程目的地坐标做区域偏置(MapKit) + 海外 proximity。
    func biasRegion(toLatitude lat: Double, longitude lon: Double) {
        guard lat != 0 || lon != 0 else { return }
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            span: MKCoordinateSpan(latitudeDelta: 1.5, longitudeDelta: 1.5)
        )
        proximity = "\(lon),\(lat)"
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // MKLocalSearchCompleter 内部串行：设新 queryFragment 会取消上一次、只回最新片段的结果，
        //   故 MapKit 这一路无需额外的乱序守卫（乱序风险只在独立 URLSession 的海外路，见 scheduleOverseas）。
        let items = completer.results
        Task { @MainActor in
            self.mapkitResults = items.map {
                PlaceSuggestion(id: "mk:\($0.title)|\($0.subtitle)", title: $0.title, subtitle: $0.subtitle, kind: .mapkit($0))
            }
            self.merge()
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.mapkitResults = []; self.merge() }
    }

    /// 海外补全:debounce 300ms(省 Mapbox 调用),≥2 字符才触发。
    private func scheduleOverseas() {
        overseasTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { overseasResults = []; merge(); return }
        let storefront = isChinaStorefront ? "CHN" : "INTL"
        let prox = proximity, sess = session, pm = placeMode
        overseasTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let r = await OverseasPlaceSource.suggest(query: q, proximity: prox, session: sess, storefront: storefront, placeMode: pm)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // 防乱序覆盖：仅当结果对应的 query 仍是当前输入时才写回（旧 query 的慢响应直接丢弃，
                //   不让 "tok" 的迟到结果盖掉 "toky"）。Task.isCancelled 只是协作标志、不保证不写，故这里再校验一道。
                guard q == self.query.trimmingCharacters(in: .whitespaces) else { return }
                self.overseasResults = r
                self.merge()
            }
        }
    }

    /// 合并:国内(高德)在前 + 海外(Mapbox),按 title+subtitle 粗去重(两源覆盖区基本不重叠)。
    private func merge() {
        var seen = Set<String>()
        var out: [PlaceSuggestion] = []
        for s in mapkitResults + overseasResults {
            let k = (s.title + "|" + s.subtitle).lowercased()
            if seen.insert(k).inserted { out.append(s) }
        }
        results = out
    }

    /// 选中后解析为最终地点(两源分流);两边都产出名称/坐标/地址/电话/时区。
    func resolve(_ s: PlaceSuggestion) async -> ResolvedPlace? {
        let storefront = isChinaStorefront ? "CHN" : "INTL"
        switch s.kind {
        case .mapkit(let completion): return await Self.resolveMapKit(completion)
        case .overseas(let mapboxId):
            let sess = session
            let result = await OverseasPlaceSource.retrieve(mapboxId: mapboxId, session: sess, storefront: storefront)
            // retrieve 终结本次 Mapbox 计费会话 → 轮换 session，下次搜索另起新会话；
            //   否则 retrieve 之后的 suggest 会脱离会话被逐条计费（发票上才看得到的隐性漏钱）。
            session = UUID().uuidString
            return result
        }
    }

    /// sheet 关闭时调用：取消在途海外请求、停掉 MapKit 补全，避免回调写入已销毁视图的状态（配合防乱序）。
    func tearDown() {
        overseasTask?.cancel()
        completer.cancel()
    }

    private static func resolveMapKit(_ completion: MKLocalSearchCompletion) async -> ResolvedPlace? {
        let request = MKLocalSearch.Request(completion: completion)
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        let item = response.mapItems.first
        let coord = item?.placemark.coordinate
        // 中国大陆境内地理时区（新疆/西藏的 Asia/Urumqi 等）归一到北京时间——当地航班/酒店都按北京时间，
        // 避免纯国内行程被误判为跨时区（见 TimeZoneCanonicalizer）。境外时区不受影响。
        let rawZone = item?.timeZone?.identifier ?? item?.placemark.timeZone?.identifier ?? ""
        return ResolvedPlace(
            name: completion.title,
            latitude: coord?.latitude ?? 0,
            longitude: coord?.longitude ?? 0,
            address: item?.placemark.title ?? completion.subtitle,
            phone: item?.phoneNumber ?? "",
            timeZoneId: TimeZoneCanonicalizer.canonical(rawZone),
            // MapKit 白拿的权威 ISO 国家码（alpha-2，大写）；境内高德源同样回传，供主目的地点亮。
            countryCode: (item?.placemark.isoCountryCode ?? "").uppercased()
        )
    }
}

// MARK: - AddStopView

struct AddStopView: View {
    let tripId: UUID
    let dayId: UUID
    /// 行程目的地坐标，用于搜索区域偏置（可为 0/0）。
    var biasLatitude: Double = 0
    var biasLongitude: Double = 0
    /// 非 nil = relocate 模式：选中结果更新该停靠点的坐标/地址/名称，而非新增。
    var relocateStopId: UUID? = nil
    /// relocate 成功后回传新名称（供调用方同步显示）。
    var onRelocated: ((String) -> Void)? = nil

    private var isRelocating: Bool { relocateStopId != nil }

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var completer = StopSearchCompleter()
    @State private var category: StopCategory = .other
    @State private var isResolving = false
    @State private var searchFocused: Bool = false   // 普通 Bool：CarrySearchField 内部走 UITextField，焦点不能用 @FocusState（见 IMESafeTextField）

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if completer.results.isEmpty && !completer.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        // 无补全结果时提供「手动添加无地点停靠点」入口。
                        Button {
                            addManualStop()
                        } label: {
                            Label {
                                Text(String(format: NSLocalizedString("itinerary.add_stop.manual", comment: ""), completer.query))
                            } icon: {
                                Image(systemName: "mappin.slash")
                            }
                        }
                    }
                    ForEach(completer.results) { result in
                        Button {
                            resolveAndAdd(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .foregroundStyle(.primary)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    if !completer.results.isEmpty {
                        Text("itinerary.add_stop.results")
                    }
                }
            }
            .listStyle(.insetGrouped)
            // 统一整屏底色：不依赖 List 在 sheet 里的隐式分组底（实测会渲染成白、与下方搜索框
            // band 的 systemGroupedBackground 割裂）。显式铺一层 grouped 底，让 band 与列表区
            // 共用同一表面，接缝从根上消除。
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            // 自定义常驻搜索框（替代 .searchable）：点击只弹键盘，不切换导航栏形态、不变背景。
            .safeAreaInset(edge: .top) { searchField }
            .disabled(isResolving)
            .overlay { if isResolving { ProgressView() } }
            .navigationTitle(Text(isRelocating ? "itinerary.stop.edit.relocate" : "itinerary.add_stop.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
            .onAppear {
                completer.biasRegion(toLatitude: biasLatitude, longitude: biasLongitude)
                // 聚焦推迟到下一帧：在 sheet 呈现的更新周期内同步设置 @FocusState 会触发
                // AttributeGraph「setting value during update」硬崩溃；且延后设置程序化聚焦更可靠。
                DispatchQueue.main.async { searchFocused = true }
            }
            .onDisappear { completer.tearDown() }   // 取消在途海外请求 + 停 MapKit 补全
        }
    }

    /// 常驻搜索框：统一 CarrySearchField（.grouped 表面），尾部收进类别菜单，固定在导航栏下方。
    private var searchField: some View {
        CarrySearchField(
            text: $completer.query,
            placeholder: "itinerary.add_stop.search_placeholder",
            focus: $searchFocused
        ) {
            // relocate 模式只换位置、不改类别，故隐藏类别菜单。
            if !isRelocating {
                Divider()
                    .frame(height: 18)
                categoryMenu
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(.systemGroupedBackground))
    }

    /// 类别收进搜索框尾部的紧凑 Menu：当前类别图标，一点切换。
    /// 加地点的主任务是搜索，类别是次要属性 → 退出结果上方、不挤占首屏（north-star §2）。
    private var categoryMenu: some View {
        Menu {
            Picker(selection: $category) {
                // 仅在地体验 + 住宿 + 兜底；交通类（航班/火车/租车/邮轮）走统一「+」交通入口。
                // spec: itinerary-car-rental.md。
                ForEach(StopCategory.placeSelectableCases, id: \.self) { cat in
                    Label(cat.titleKey, systemImage: cat.symbolName).tag(cat)
                }
            } label: {
                Text("itinerary.add_stop.category")
            }
        } label: {
            Image(systemName: category.symbolName)
                .font(.system(size: 15))
                .foregroundStyle(CarryAccent.color)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .tint(CarryAccent.color)
        .accessibilityLabel(Text("itinerary.add_stop.category"))
    }

    /// 解析补全项的真实坐标后入库。解析失败则退回无坐标停靠点（仍保留名字）。
    private func resolveAndAdd(_ suggestion: PlaceSuggestion) {
        isResolving = true
        Task {
            let r = await completer.resolve(suggestion)   // 国内走 MapKit、海外走 Worker;两源同构返回
            isResolving = false
            guard let r else {
                // 解析失败（网络/上游/无坐标）→ 退回无坐标停靠点、保留用户选中的名字，不让点击石沉大海。
                addFallbackStop(named: suggestion.title)
                return
            }
            if let relocateStopId {
                // relocate：地点整体换了 → 名称/坐标/地址/电话/时区一并更新（类别保持不变）。
                store.updateItineraryStop(
                    tripId: tripId, stopId: relocateStopId,
                    name: r.name, latitude: r.latitude, longitude: r.longitude,
                    address: r.address, phone: r.phone, timeZoneId: r.timeZoneId
                )
                onRelocated?(r.name)
            } else {
                store.addItineraryStop(
                    tripId: tripId, dayId: dayId,
                    name: r.name, latitude: r.latitude, longitude: r.longitude,
                    address: r.address, category: category, phone: r.phone, timeZoneId: r.timeZoneId
                )
            }
            dismiss()
        }
    }

    /// 解析失败时的回退：用给定名字落一个无坐标停靠点（relocate 则改名清坐标），与「手动添加」同构。
    private func addFallbackStop(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { dismiss(); return }
        if let relocateStopId {
            store.updateItineraryStop(tripId: tripId, stopId: relocateStopId,
                                      name: name, latitude: 0, longitude: 0, address: "", phone: "")
            onRelocated?(name)
        } else {
            store.addItineraryStop(tripId: tripId, dayId: dayId, name: name, category: category)
        }
        dismiss()
    }

    private func addManualStop() {
        let name = completer.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let relocateStopId {
            // relocate 到无坐标地点：改名并清空坐标/地址/电话（变回「无定位停靠点」）。
            store.updateItineraryStop(
                tripId: tripId, stopId: relocateStopId,
                name: name, latitude: 0, longitude: 0, address: "", phone: ""
            )
            onRelocated?(name)
        } else {
            store.addItineraryStop(tripId: tripId, dayId: dayId, name: name, category: category)
        }
        dismiss()
    }
}
