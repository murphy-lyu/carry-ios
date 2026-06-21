# 海外地点检索（Overseas POI Search）

**Status:** Draft — 待用户确认后实现
**提出:** 2026-06-21（时区实测时撞到，见记忆 carry-overseas-poi-search-gap）
**关联:** itinerary-airport-search.md（机场库范式）/ itinerary-flight-search-first.md（Worker 代理范式）/ itinerary-timezone.md（坐标→时区）

---

## 1. 问题与根因

Carry 的「地点 / 住宿」检索用 MapKit（`StopSearchCompleter` = `MKLocalSearchCompleter` + `MKLocalSearch`）。在**中国大陆区域**的设备上，Apple 地图后端按法规换成**高德（AutoNavi）**，**只覆盖中国大陆 + 港澳，搜不到海外 POI**。

→ 对一个**国际旅行** App，大陆用户**加不了海外地点 / 住宿**（巴黎餐厅、东京酒店都搜不到）。这是核心缺口。

**根因不可绕**：中国境内地图须用持测绘资质的本地数据，**MapKit 自身无法切换到全球覆盖**。必须引入**第二个全球数据源**。

但有两条约束：
- 高德对**国内**本地 POI 最准、且**合规**——国内不能弃高德。
- 用境外数据源描绘**中国境内**地点 / 边界是**合规红线**——全球源只能用于境外。

---

## 2. 目标 / 非目标

**目标**
- 大陆用户能搜到**海外**地点 / 住宿并加入行程（名称 + 坐标 + 地址 + 时区）。
- 国内检索体验、合规性**不变**（仍走高德）。
- 与已做的时区功能衔接：海外地点也带 IANA 时区。

**非目标**
- 不替换地图**渲染**（地图仍是 MapKit/高德，不引入境外底图/边界）。
- 不做「国内/海外」手动开关（复杂度推给用户，违背克制）。
- 不追求覆盖每一家海外小店（地标/酒店/餐厅级别即可，v1）。

---

## 3. 设计:混合检索（高德 + Mapbox），合一个搜索框

**一个搜索框,底层并行查两路、合并去重:**

1. **国内 + 港澳** → 继续 **MapKit（高德）**。准、快、合规。时区取 `MKMapItem.timeZone`（已实现）。
2. **海外** → **Mapbox Search Box API**，经**自家 Cloudflare Worker** 代理。**只取「非中国」结果**（country ∉ {CN, HK, MO}）——中国境内一律由高德出，境外由 Mapbox 出。**这是合规关键。**

**合并**:高德国内结果 + Mapbox 境外结果，去重（两者覆盖区基本不重叠，去重简单）后单列表呈现。用户无感知,搜什么都能出。

### 3.1 为什么 Mapbox
全球 POI 覆盖好、Search Box API 专为 typeahead 检索设计、文档成熟、有免费额度、运维轻（只需 key + 缓存,无需自建服务器）。provider 藏在 Worker 后,将来换 Geoapify/OSM **只改 Worker、App 不动**（同航班「换市场只改 Worker」）。

---

## 4. Worker 设计（`carry-search`,复用航班 Worker 范式）

新增一个 Worker,绑自定义域名(如 `search.nevestudio.app`,或复用 `config` 同账号),职责:
- **代理 Mapbox Search Box**:`/suggest`(自动补全,带 session token)+ `/retrieve`(选中取坐标)。两端各转发一条。
- **藏 key**:Mapbox token 只在 Worker secret(`MAPBOX_TOKEN`),不进 App/git(同 `FlightLookupService` 的 Secrets 范式)。
- **缓存**:`/suggest` 按「query + proximity + session」短 TTL 缓存;`/retrieve` 按 mapbox_id 长 TTL。自动补全啰嗦,缓存是控成本的关键。
- **app-token 门槛 + 限流**:同航班(`X-App-Token` + Rate Limiting 绑定),挡盗刷。
- **坐标→IANA 时区**:Worker 内用极小离线库(如 `tz-lookup`,~几十 KB)由 lat/lon 算 IANA tz,随结果返回——**海外地点的时区由此而来**,直接喂时区功能。
- **过滤**:在 Worker 或 App 侧滤掉 country ∈ {CN,HK,MO} 的结果(合规 + 去重,留给高德)。建议 Worker 侧滤,App 只管合并。
- 国内可达:走自家域名,规避 GFW(同 `flight`/`config`)。

返回给 App 的结构对齐现有回调:`name, latitude, longitude, address, phone(可空), timeZoneId`。

---

## 5. App 集成

- 新增 `OverseasPlaceSource`(actor / service):对 Worker 的 `/suggest`+`/retrieve` 封装,产出与 MapKit completion 同构的候选 + resolve。
- `StopSearchCompleter`(AddStopView)与 `ItineraryPlaceSearchSheet` 改为**双源**:MapKit completer + OverseasPlaceSource 并行,结果合并发布。
  - **debounce**(~300ms)再触发 Mapbox(省额度);MapKit completer 自带节流。
  - proximity bias:两源都按行程目的地坐标偏置(`bundle.latitude/longitude`)。
- 选中海外结果 → 回调已带 `timeZoneId`(Worker 给);选中国内结果 → `MKMapItem.timeZone`(已实现)。两条路殊途同归,下游(stop/lodging/transport 录入)无需分叉。
- 复用现有回调签名(`onSelect(name, lat, lon, address, phone, timeZoneId)`),改动集中在「搜索结果来源」层。

---

## 6. UX(克制)
- 搜索框、交互**不变**。无「国内/海外」开关。
- 结果合并:有国内结果时国内在前;海外查询自然全海外。来源不显(或极小灰字,默认不显)。
- 加载:两源并行,谁先回谁先显;Mapbox 经 debounce。

---

## 7. 成本控制
- **debounce + 缓存**(Worker 端 + 可选 App 端):把自动补全调用压到最低。
- Mapbox **session 计费**(suggest…retrieve 算一次 session)——正确串 session token,避免每次按键计费。
- app-token 门槛 + 限流挡盗刷。
- 监控 Mapbox 用量;超免费额度按量付费(缓存后通常很省)。provider 可换(藏 Worker 后)。

---

## 8. 隐私政策（carry-legal,必做）
地点查询字符串会发给第三方（Mapbox)——与航班号发查询同理,需在 `carry-legal` 的 `privacy/zh.html` + `index.html`(中英同步、PIPL 第 14 条不删)补一条「地点检索经第三方(Mapbox)处理」。直接改并 push(用户长期授权)。

---

## 9. 合规(大陆上架)
- 全球源**只用于境外结果**,中国境内描绘全留高德 → 不踩测绘红线。
- 不引入境外**底图/边界渲染**(地图仍 MapKit/高德)。
- `isChinaStorefront` 不影响本功能逻辑(双源对所有 storefront 都开;海外用户本来 MapKit 就全球可用,Mapbox 作补充/冗余,或可在非大陆 storefront 关 Mapbox 省额度——见开放问题)。

---

## 10. 分期
- **Phase 1**:`carry-search` Worker(Mapbox 代理 + 缓存 + app-token + 坐标转时区 + 滤境外)上线 + 验证国内可达。
- **Phase 2**:App 双源合并(AddStopView + ItineraryPlaceSearchSheet),debounce,选中带时区。
- **Phase 3**:隐私政策更新;用量监控;打磨(去重/排序/proximity)。

---

## 11. 开放问题(实现前定)
1. Worker 域名:复用 `config.nevestudio.app`(加 `/search` 路径)还是新 `search.nevestudio.app`?(倾向新子域,职责清晰)
2. 非大陆 storefront 是否也开 Mapbox(冗余、更全)还是只大陆开(省额度)?(倾向:都开,体验一致;额度不够再收。)
3. Mapbox 用 **Search Box**(session,typeahead 体验好)还是 **Geocoding v6**(per-request,简单)?(倾向 Search Box。)
4. 是否需要把已加的「海外地点无时区」历史数据回填?(可不做,用户重选即捕获。)

---

## 验收要点(实现后)
- 大陆设备无 VPN:搜「Eiffel Tower / Louvre / Tokyo Station」返回**真巴黎/东京**结果并可加入;国内地点仍由高德、体验不变。
- 选中海外地点 → 名称/坐标/地址/**时区**齐全;时间轴 Day 头时区小标正确(衔接时区功能)。
- 成本:连续输入只触发受控的几次 Mapbox 调用(debounce + 缓存生效)。
