# Performance Audit — 2026-05-27

审计范围：App 启动 → MapKit 初始化 → 首页行程卡片 → 物品清单 → Add Items → 搜索 → 场景推荐 → Surprise Items → 保存清单 → 创建/编辑行程 → Auto Pack 完整链路。

---

## 问题汇总

### ✅ P1 — save() 触发全量 fetch + 同步磁盘备份（已修复 2026-05-27）

**位置：** `TripStore.save()` → `fetchTrips()` → `DataBackupManager.backup()`

**描述：**
每一次数据写操作（勾选打包、改物品名、dismiss 惊喜物品、改场景、dismiss 场景卡片等）都会触发：
1. `context.save()` — SwiftData 写入
2. `fetchTrips()` — 重新 fetch 所有 TripBundle + MyItem
3. `DataBackupManager.backup()` — 全量 JSON 编码 + 同步写磁盘

三步全部在主线程同步执行。用户数据量小时主观无感知，行程和物品较多时每次写操作都有轻微阻塞风险。

**影响范围：** 所有写操作路径。

**修复方案：** `DataBackupManager.backup()` 里，`@Model` 属性映射（`TripBundle` → `BackupTrip`）保留在主线程（SwiftData 关系属性必须在主线程访问）；JSON encode + 磁盘写入改为 `Task.detached(priority: .utility)` 异步执行。`CarryBackup` 是纯 Codable 值类型，跨线程安全。每次写操作不再阻塞主线程等待磁盘 I/O。

---

### 🟡 P2 — packedCount / totalCount 无缓存

**位置：** `TripBundle` computed properties（TripStore.swift L96–97）、HomeView 行程卡片 `.id()` modifier

```swift
var packedCount: Int { safeSections.flatMap { $0.items ?? [] }.filter { $0.isPacked && !$0.name.isEmpty }.count }
var totalCount:  Int { safeSections.flatMap { $0.items ?? [] }.filter { !$0.name.isEmpty }.count }
```

**描述：**
两个属性每次访问都完整遍历所有 section + items。HomeView 卡片的 `.id()` 包含这两个值，SwiftUI 每次渲染都读取；`rebuildTripLists()` 排序时也访问。行程少时无感知，行程多物品多时会累积。

**建议方向：** 在 `fetchTrips()` 后计算并缓存到字典，或在 SwiftData Model 上加 stored property（需 migration）。后者风险较高。

---

### ✅ P3 — localizedSearchTermsByItem 搜索冷启动（已修复 2026-05-27）

**位置：** `ItemPickerView.localizedSearchTermsByItem`（静态 lazy 初始化）

**描述：**
`static let` 在用户首次输入搜索词时执行，遍历所有 lproj bundle（8 种语言），为全部物品建立多语言搜索索引。第一次搜索可能有几十毫秒延迟，之后永久缓存，无问题。

**修复方案：** 在 `ItemPickerView.onAppear` 里加 `_ = ItemPickerView.localizedSearchTermsByItem`，将冷启动时机从"用户输入第一个字"提前到"界面打开时"，用户无感知。

---

## 已确认无问题的链路

| 链路 | 结论 |
|------|------|
| App 启动（CarryApp + SplashView） | ContentView 在 splash 期间预热，设计正确 |
| ModelContainer 初始化 | static let，进程级单例，正确 |
| geocodeMissingTrips | 有 guard 保护 + 本地表快速路径 + rate limiting，正确 |
| generatePackingSections | 纯内存 O(n)，有界数据，无问题 |
| computeSurpriseItems | O(n) + 一次 sort，数据有界，无问题 |
| rebuildSurpriseItems | 有 cachedSurpriseItems 缓存，按需重建，正确 |
| sceneRecommendedNames | 已于 2026-05-27 修复（init 预计算缓存） |
| mergeItems 批量写入 | 循环 insert + 统一 save，正确 |
| Auto Pack init 预计算 | 已于 2026-05-27 修复（复用 generatePackingSections 结果） |

---

## 待跟进优化项

- [x] P1：backup() 异步化 — 已于 2026-05-27 实施
- [ ] P2：packedCount/totalCount 缓存方案设计（待评估）
- [x] P3：ItemPickerView.onAppear 提前 warm-up localizedSearchTermsByItem — 已于 2026-05-27 实施

---

*下次审计建议在新增大型功能（航班、酒店等）后重新扫描数据层写操作频率。*
