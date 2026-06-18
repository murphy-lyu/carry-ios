# Photo Trip Reconstruction（照片回溯行程 — 从相册自动生成行程规划）

> **Status: Implemented (Phases 1–4) — 编译绿（Carry / iPhone 17 Pro）+ 聚类内核单测 7 断言 PASS + 模拟器启动不崩（新 schema 迁移已验）。待真机验收（选带 GPS 真照片走完生成→编辑→保存）。未提交。**
>
> **实现落点（文件）：**
> - 内核（纯函数，可单测）：`Carry/Models/CoordinateTransform.swift`（WGS-84→GCJ-02）、`Carry/Models/ItineraryPhotoClustering.swift`（分天+时空切地点）。
> - 读取与编排：`Carry/Models/PhotoTripReconstructor.swift`（extract 从 PHPicker 所选图数据直读 EXIF / assemble 聚类+命名）、`Carry/Models/PhotoItineraryDraft.swift`（内存草稿值类型）。**零相册授权**（不碰 PHAsset，已删 `PhotoLibraryAccess.swift`）。
> - 落库：`StopPhoto` @Model + `ItineraryStop.photos`/`fromPhotos`（`Itinerary.swift`）、`SchemaV1` 注册（`CarrySchema.swift`）、`TripStore.importItineraryFromPhotos`、`DataBackupManager`（备份/还原带缩略图字节，分享路径不带）、`duplicateTrip` 深拷、`CarryLogger` 5 个 `photoImport*` 事件。
> - UI：`Carry/Views/PhotoTripImportView.swift`（状态机：intro/processing/review/denied/empty + PHPicker）、`Carry/Views/PhotoTripReviewView.swift`（改名/类别/合并/拆分/挪照片/删点/待整理/松紧档）、`ItineraryView` 工具栏入口（仅有日期行程）。
> - 文案：`Info.plist` 加 `NSPhotoLibraryUsageDescription`；`Localizable.xcstrings` 加 36 个 `phototrip.*` 键、`InfoPlist.xcstrings` 加权限文案，均 9 语言。
>
> **与原 Draft 的偏差（已实现版）：**
> 1. 合并/拆分用**菜单动作**而非拖拽手势——稳、零学习成本，不与 List 手势冲突；拖拽留作后续打磨。
> 2. 离群单点**不自动丢进待整理**（避免误删真地点）。宁可多生成让用户删。
> 3. 类别不做时段猜测，统一默认 `.sightseeing`，用户改。
> 4. **不做松/紧档切换**（用户反馈：三档肉眼基本无差、徒增选择负担）——固定用「适中」，一开始不做复杂。`PhotoClusterConfig` 三档预设保留在内核，UI 不暴露。
> 5. **零相册授权 + 直读所选图 EXIF**（隐私最优，2026-06-18 定稿）：不请求相册权限、不碰 `PHAsset`、不传 `photoLibrary` 给 picker——彻底没有「访问所有照片」弹窗（隐私敏感用户最大顾虑）。`PhotosPickerItem.loadTransferable(Data)` → `CGImageSource` 读 EXIF GPS + DateTimeOriginal + 降采样缩略图，与系统相册同源，顺带消除「相册有位置、Carry 说没有」。取舍：逐张载入原图数据略重（40 张上限 + 进度态兜住）；不存 assetLocalIdentifier（不绑库），故本版不做「回相册看原图」。`NSPhotoLibraryUsageDescription` 已移除（不再需要）。
> 6. **「待整理」拆成两个诚实区块**：`没有位置信息`（文件真无 GPS）与 `不在行程日期内`（有位置但拍摄日越界，并显示拍摄日）。原单一「待整理 = 没位置」标签会把「日期越界」误标成「没位置」，误导用户以为 App 有 bug。`PhotoItineraryDraft.unsorted` 拆为 `noLocation` + `outOfRange`。
> 7. **单次导入上限 40 张**（`maxSelectionCount`）+ 落库追加语义（可多次导入）——控制生成 stop 数 / 处理耗时 / 内存。
> 8. **入口收进右上角「更多」菜单**（非显眼直出按钮）——偏小众 + 涉相册权限。仅有日期行程显示。
> 9. **导入首屏加隐私安心文案** + 文案去工程味（标题「从照片还原行程」）。
> 10. **长行程滚动性能**：focused 天回写改「滚动停下才触发」，避免滚动中整页重建（详见 `docs/decisions.md` 2026-06-18 + `progress.md`）。更深的地图/memoization 优化留真机 profile。
>
> ---
> **（原 Draft 内容如下，保留作设计依据）**
>
> **已确认的产品决策（来自需求讨论）：**
> 1. **方向 = 正向规划的镜像**：现有行程是「出发前做规划」的正向流；本功能加一条「玩完之后把相册照片回溯成行程」的反向流。两者共享同一个 `TripBundle` / `ItineraryDay` / `ItineraryStop`，不另起数据结构。
> 2. **照片存储策略 = 缩略图入库 + 原图引用相册**：每张照片存「相册 `localIdentifier` 引用 + 一张小缩略图字节」。App 不囤原图（省空间），行程页/备份/换机都能看到缩略图，点开看原图回相册取。对标 Apple 自家做法。
> 3. **第一版只做主线**：建行程定日期 → 选图 → 读 EXIF → 聚类 → 命名 → 预览微调 → 保存。**不做**：手动加点位之外的高级编辑、跨人照片合并、与正向规划流的双向同步、地图轨迹连线、两层「景区→地点」折叠（schema 留好、本轮不实现）。
> 4. **生成结果是「草稿」不是「结果」**：聚类永不可能 100% 准，体验命门在「90% 自动生成 + 那 10% 改起来顺手」，而非追求算法满分。预览页是必经的确认关，绝不自动落库。

## 动机

`itinerary-route-planning.md` 已落地「出发前手动按天排地点」。但有一类用户（及场景）正向流覆盖不到：

- **不是每个人出发前都会认真做规划**，但几乎每个人玩的时候都会拍照。照片是「我真的去过、真的待在那儿」的最诚实轨迹。
- 用户想要的是一个**记录真正去玩过的行程**的地方：去了新疆，玩了 N 个地点，每个地点拍了些照片，事后能一键攒成一份有时间轴、有地点、有照片的回忆型行程。

照片 EXIF 里天然藏着三样关键信息——**拍摄时间**、**GPS 经纬度**、设备型号（次要）——合起来就是一条「时间 + 空间」足迹。本功能把「相册里的一堆照片」变成「一份回溯型行程」，与正向规划互为镜像：一个面向未来，一个面向过去。

## 核心设计原则

1. **复用现有行程结构，不另起炉灶**：回溯生成的产物就是普通的 `ItineraryDay` + `ItineraryStop`，落地后与手动排的行程完全同质——能在同一个行程详情页查看、编辑、导出。照片是 `ItineraryStop` 新挂的一层 `StopPhoto`。
2. **写入只走 TripStore 漏斗**：聚类/地理编码是重活、异步，在 off-main `Task` 里算；算完经 TripStore 新增的**单一批量漏斗** `importItineraryFromPhotos(...)` 一次性落库（禁止 View 直写 `@Model`，呼应 CLAUDE.md 铁律）。
3. **草稿态先于落库**：聚类结果先以**内存草稿**渲染预览页，用户点「保存」才落库。绝不在用户未确认时写入行程。
4. **顺着框架机制，不对抗**：用 `PhotosUI.PHPicker` 取 `assetIdentifier` → `PHAsset` 读 `location`/`creationDate`；缩略图走 `PHImageManager`。不自造相册访问层。
5. **坐标系一次做对**：EXIF GPS 是 WGS-84；项目库内坐标在境内存 GCJ-02（见 `MapNavigationService`）。境内照片坐标必须先 WGS-84→GCJ-02 转换再存库与反向编码，否则地图整体偏移、地理编码编错街区。
6. **边界有感知、不打断**：无相册权限 / 仅部分授权 / 照片无 GPS / 截图无 EXIF / 拍摄日期落在行程区间外——统一收进「待整理」抽屉，可手动归位，绝不报错、绝不丢照片。
7. **加字段、可选、轻量迁移**：新增 `StopPhoto` model（加表，轻量迁移）；新增字段一律可选带默认；`DataBackupManager` 同步带缩略图字节、`duplicateTrip` 深拷贝（CLAUDE.md 备份/费用四处同步规则）。

## 数据模型

### 新增 StopPhoto（ItineraryStop 的 cascade 子节点）

```swift
/// 一张挂在停靠点上的照片。真相 = 相册引用 + EXIF 元数据；
/// 缩略图字节随库/备份走，原图永远回相册按 assetLocalIdentifier 取（App 不囤原图）。
@Model final class StopPhoto {
    var id: UUID = UUID()
    var assetLocalIdentifier: String = ""   // PHAsset.localIdentifier，回相册取原图
    var thumbnailData: Data = Data()         // 小缩略图（约 200pt@2x JPEG），列表/备份用
    var timestamp: Date = Date()             // EXIF 拍摄时间（PHAsset.creationDate）
    var latitude: Double = 0                 // 已转 GCJ-02（境内）/ WGS-84（境外）
    var longitude: Double = 0
    var sortOrder: Int = 0                   // 地点内按时间排
    var stop: ItineraryStop?
}
```

### ItineraryStop 扩展（加一层关系，不改既有字段）

```swift
@Model final class ItineraryStop: CostBearing {
    // …既有字段不动…
    @Relationship(deleteRule: .cascade, inverse: \StopPhoto.stop)
    var photos: [StopPhoto]? = []

    var sortedPhotos: [StopPhoto] { (photos ?? []).sorted { $0.sortOrder < $1.sortOrder } }
}
```

### 来源标记（provenance）

行程详情页要能识别「这趟/这个地点是照片回溯生成的」（用于 UI 标识、未来重新生成、埋点区分）。最小化加一个可选标记：

```swift
@Model final class ItineraryStop {
    var fromPhotos: Bool = false   // 是否由照片回溯生成（用户手动编辑后仍保留该出身标记）
}
```

> `TripBundle` 不单独加「整趟来源」标记——一趟行程可能正向手排 + 回溯生成混合，来源属于 stop 粒度更准确。是否「该趟含照片生成的地点」由 `stops.contains { $0.fromPhotos }` 派生。

## 聚类算法（功能命门 — 纯函数、可单测、不碰 SwiftData）

输入 `[(timestamp: Date, coordinate: CLLocationCoordinate2D)]`（已转 GCJ-02、已按行程日期区间过滤、已剔除无 GPS），输出 `[Day → [Place(质心, 起止时间, 成员照片索引)]]`。独立文件 `ItineraryPhotoClustering.swift`，输入输出皆值类型，便于单测。

### 步骤

**0. 预处理**：取拍摄时间落在 `[出发日 00:00, 返程日 23:59]` 内、且有 GPS 的照片，按拍摄时间升序排序。

**1. 分天（凌晨 cutoff，非死板自然日）**
- 按 EXIF 本地拍摄时间分天，切点设在**凌晨 04:00**（默认 `dayCutoffHour = 4`）：04:00 前的照片算前一天。避免「夜市逛到凌晨」「凌晨看日出」被劈成两天。
- `dayOrder = 该照片归属日 − 出发日`（按天数差），对齐 `ItineraryDay.sortOrder`（0-based）。

**2. 地点切分（时空一起判，单层）**
沿时间轴走，维护「当前地点」的质心与成员，按下列规则吞并/切分（阈值见下表）：
- `距质心 ≤ R_place` → 同一地点，并入，更新质心。
- `距质心 > R_place 但 <T_return 内走远又折返到质心附近` → 视为同地点内走动（大景区里逛动几百米，不切碎），仍并入。
- `距质心 > R_place 且持续远离` → 关闭当前地点，开新地点。
- **离群单点**（仅 1 张、前后都在别处、像路上随手拍）→ 标记为「途中」，不单独成地点（归入「待整理」或相邻地点，取近者；本版先归「待整理」简单稳妥）。

**3. 地点内排序与时段**：地点内照片按时间升序；`plannedStartMinutes` = 首张照片自当天本地午夜的分钟数；`stayMinutes` = 末张 − 首张（≥ 0；单张照片为 0）。

**4. 天内排序**：天内地点按各自首张照片时间升序 → 自然时间轴，写 `ItineraryStop.sortOrder`。

**5. 命名（魔法时刻）**：对每个地点质心 `CLGeocoder.reverseGeocodeLocation` 反查 POI 名 → 写 `name` + `address`。沿用项目已有 ~1 req/s 限流范式（见 `TripStore` 现有 CLGeocoder 调用）。拿不到 POI 则退「街道 → 城市 → "地点 N"」。**类别**：EXIF 不含类别，统一默认 `.sightseeing`，由用户在预览页改（不做时间段猜餐饮等过度智能）。

### 阈值（做成可调，给「松 / 中 / 紧」三档预设，预览页可一键切换重算）

| 参数 | 默认（中档） | 作用 |
|---|---|---|
| `R_place` 地点半径 | 200 m | 多近算「同一个地方」 |
| `T_return` 折返时窗 | 15 min | 短暂走开多久内算没离开 |
| `dayCutoffHour` 凌晨切点 | 04:00 | 跨午夜归哪天 |
| `R_area` 区域半径（预留） | 3 km | 第二层「景区→地点」折叠，本版**不实现**，参数与字段留好 |

> 软边界辅助：若相邻两张照片间存在「超长空档（>5h）+ 明显位移」，可作为天/段切分的辅助信号（与凌晨 cutoff 二选一更稳的那个），本版可先只用 cutoff，留作后续打磨。

## 坐标系转换（境内必做）

- EXIF GPS = WGS-84 原始值；境内项目坐标 = GCJ-02（Apple/高德直传，见 `MapNavigationService`）。
- 在境内 storefront 下，照片坐标写库前必须 **WGS-84 → GCJ-02**（标准 eviltransform 偏移算法），再用于反向地理编码与地图渲染；境外坐标保持 WGS-84。
- 判据沿用项目既有 `isChinaStorefront`（`SceneItemMap.swift`），**禁止**用设备 Locale 替代 storefront 判断（CLAUDE.md 政策合规约定）。
- 转换工具放独立 `nonisolated` 文件（如 `CoordinateTransform.swift`），便于在 async Task 里自由调用、并单测已知坐标对。

## 交互流程（5 步 + 预览微调页）

1. **建行程 + 框日期**：用户建「新疆」，设出发/返程日（沿用现有建行程流 + `syncItineraryDays` 自动建天）。日期区间是照片过滤窗口。
2. **入口**：行程详情页「行程」面（route-planning 的第二张脸）提供「从照片生成」动作。
3. **智能选图**：`PHPicker` 选图；理想态预筛「这段日期 + 带位置」的照片并提示数量（`"找到 N 张这段时间、带位置的照片"`）。需 `NSPhotoLibraryUsageDescription`。
4. **后台处理**：off-main `Task` 跑「读 EXIF → 坐标转换 → 聚类 → 反向地理编码 → 生成缩略图」，给有进度感的等待态（不白屏）。
5. **预览 / 微调页（必经确认关）**：把生成的草稿时间轴摊开：`Day N ▸ 地点（M 张，时段）`，每地点挂缩略图与小地图点。支持：
   - **改名**（铅笔直接露在标题边——反向编码偶尔给怪名，改名优先级最高）
   - **合并**（选中地点 → 点相邻地点合并）
   - **拆分**（进地点按时间拖一刀）
   - **挪照片 / 删点**
   - **切换松/中/紧档**重算
6. **保存 → 落库**：点「保存」才经 `importItineraryFromPhotos(...)` 批量写入；顶部文案用「保存」而非「完成」，潜台词是「这是给你改的初稿」。

### 「待整理」抽屉（边界的落点）

无位置 / 截图 / 日期越界 / 离群单点的照片收进预览页底部「待整理 · N 张」抽屉，可拖到任意一天/地点。完全没授权相册 → 引导去设置开权限，同时仍允许「纯手动按天加点」兜底。

## TripStore 批量写入漏斗

新增单一漏斗，一次性建 stop + photo、**只 `save()` 一次**（避免 N 次单点 `addItineraryStop` 各存库一次、各触发一次 day-sync）：

```swift
@discardableResult
func importItineraryFromPhotos(
    tripId: UUID,
    draft: PhotoItineraryDraft   // 预览页确认后的草稿：[dayOrder → [PlaceDraft(name, coord, startMinutes, stayMinutes, category, photos)]]
) -> Bool
```

- 写入前确保 `syncItineraryDays` 已按行程日期建好天；按 `dayOrder` 找到对应 `ItineraryDay`，批量插 `ItineraryStop` + `StopPhoto`，统一 `sortOrder`。
- 所有 stop 标 `fromPhotos = true`。
- 末尾单次 `save()` + 单条埋点（见下）。

## 迁移与备份（铁律四处同步）

1. **SwiftData 迁移**：新增 `StopPhoto` model + `ItineraryStop.photos` 关系 + `fromPhotos` 字段 → 走 `CarrySchema` 的 versioned schema 新版本 + `CarryMigrationPlan` 迁移阶段（加表 + 加可选字段属轻量迁移）。**禁止**就地改 schema。
2. **DataBackupManager**：`StopPhoto` 进备份/还原序列化，**含 `thumbnailData` 字节**（缩略图不在相册、属「关联文件字节」，必须随备份带上，否则还原后缩略图丢失——CLAUDE.md 备份约定）。`assetLocalIdentifier` 一并带上（换机后原图可能取不到，UI 退化为「仅缩略图」，可接受）。发布前新增可选字段**不升** `currentBackupVersion`。
3. **duplicateTrip**：深拷贝 `ItineraryStop` 时一并深拷 `photos`（`StopPhoto` 全字段含缩略图字节），呼应费用四处同步同款规则。
4. **费用**：`StopPhoto` 不涉及费用，无需碰 `CostBearing` 四点。

## 埋点（CarryLogger，闭环：定义即接线）

在 `CarryLogger.Event` 新增并**同一改动接好调用点**（禁止先定义后接线）：
- `photoImportStarted`（进入选图）
- `photoImportGenerated`（聚类完成、进预览页；带地点数/照片数/天数维度）
- `photoImportSaved`（点保存落库）
- `photoImportCancelled`（预览页放弃）
- 错误类（无 GPS 照片占比过高、地理编码失败等）按需新增并并入 `errorEvents`。

## 本地化

所有新文案（入口、空态、待整理、预览页动作、权限引导、阈值档位）进 `Localizable.xcstrings`，结构化 key 显式写 `en`，同步补全 9 种语言；中文用全角标点。用户数据（地点名/相册原名）原样不翻译。

## 分阶段实现（schema 一次设计全，编码分阶段）

- **Phase 1 — 读取 + 聚类内核**：`PHPicker` 取 asset → `PHAsset` 读 location/time → 坐标转换 → `ItineraryPhotoClustering` 纯函数 + 单测（已知坐标/时间序列）。先不落库，console 验证聚类质量。
- **Phase 2 — 反向编码 + 缩略图 + 草稿模型**：命名、生成缩略图、组装 `PhotoItineraryDraft`。
- **Phase 3 — 预览/微调页 UI**：草稿渲染 + 改名/合并/拆分/挪照片/删点 + 待整理抽屉 + 档位切换重算。
- **Phase 4 — 落库漏斗 + 迁移 + 备份 + duplicate + 埋点 + 本地化**：`importItineraryFromPhotos` + `StopPhoto` 迁移 + 四处同步 + 埋点接线 + 9 语言文案。

## 明确不在本功能内（克制边界）

- 跨人/多设备照片合并去重
- 与正向规划流的双向同步（生成后即普通行程，不回链照片为「来源」反向编辑原图）
- 地图上照片轨迹连线
- 两层「景区 → 地点」折叠（字段/参数留好，本版单层）
- 基于画面内容（非 EXIF）的地点/类别识别
