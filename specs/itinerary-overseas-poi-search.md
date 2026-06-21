# 海外地点检索（Overseas POI Search）

**Status:** Phase 1（Worker）✅ + Phase 2（App 双源集成）✅ 编译绿,待 App 内 UI 实测（输中文地名搜海外）
**实现要点（2026-06-21）**:provider = **Mapbox**(经 `carry-places` Worker:代理 + 缓存 + 中文→英文翻译[Azure Translator] + 坐标转时区[tz-lookup] + 只回境外 + `OVERSEAS_POLICY` 运控)。Worker curl 实测通过(卢浮宫→Louvre Museum、坐标+时区、中国境内过滤)。App 侧把 `StopSearchCompleter` 重构为**统一模型 `PlaceSuggestion` + 双源**(MapKit/高德 国内 + `OverseasPlaceSource` 海外,debounce 300ms,合并去重,选中按源分流解析),AddStopView + ItineraryPlaceSearchSheet 共用。Secrets.plist 加 `PlacesProxyAppToken`。**翻译用 Azure(非 DeepL/中国源):DeepL 绑卡受限;Mapbox 海外无中文别名、`language=zh` 毁排序 → 一律英文查 + 中文 query 先翻英文。**
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

## 11. 决策(已定 2026-06-21)
1. **Worker 域名 = `places.nevestudio.app`**（按功能精准命名,与 `flight.`/`config.` 一脉;不用 `map*`——我们不提供地图渲染,且 "map" 在合规语境上有误导）。
2. **策略服务端可控（运控,见 §12）**：起步**全 storefront 都开 Mapbox**（体验一致）;成本若 Cover 不住,在 **Worker 端一键切**「仅大陆开 / 关闭」,**无需 App 发版**。
3. **Mapbox 用 Search Box**（session typeahead,体验最好）——追求最优体验,定了。
4. **不做回填**：App 未上线、无在野历史数据;本地少量测试数据重选即捕获时区。此问题随「未上线」自然消解。

## 12. 服务端可控策略（运控,§11.2 的最优落地）

不另建后台——**Worker 即控制面**(单一咽喉:App 永远只调 Worker)。

- **App 始终调 Worker**(客户端无 per-storefront 分支、行为统一);请求带上 `storefront`/region。
- **Worker 按服务端策略决定是否真去 Mapbox**:策略存 Worker 的**环境变量/配置**(Cloudflare 后台即时改),例如 `OVERSEAS_POLICY = all | cn_only | off`:
  - `all`(起步):任何 storefront 都代发 Mapbox。
  - `cn_only`:仅大陆 storefront 代发(非大陆本来 MapKit 就全球可用,省额度)。
  - `off`:全关(返回空,App 自然只剩高德)。
- **好处**:成本/可用性策略**随时在 Cloudflare 改、零发版、零审核**;客户端永远不用动。与 Carry 既有「内置默认 + 远程下发」哲学一致(roadmap.json / 航班换市场只改 Worker)。
- 可进一步细化:按 region 限流、按额度自动降级——都在 Worker 内,App 无感。

---

## 验收要点(实现后)
- 大陆设备无 VPN:搜「Eiffel Tower / Louvre / Tokyo Station」返回**真巴黎/东京**结果并可加入;国内地点仍由高德、体验不变。
- 选中海外地点 → 名称/坐标/地址/**时区**齐全;时间轴 Day 头时区小标正确(衔接时区功能)。
- 成本:连续输入只触发受控的几次 Mapbox 调用(debounce + 缓存生效)。
