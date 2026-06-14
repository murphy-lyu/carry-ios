# 打包清单：左滑「编辑」重命名物品

> **Status: Implemented（编译绿，待真机验收）。** 关联：`Carry/Views/PackingListView.swift`（swipe 接线 `beginRename` + commitEdit 防误删）、`Carry/Views/ReorderableItemCollection.swift`（加 `onEdit` swipe action，镜像 `ItineraryReorderCollection`）、`Carry/Models/TripStore.swift`（复用 `updateItemName`）。
>
> **实现选型变更（优于原 Proposed 的 alert 方案）**：打包列表本就有一套行内编辑机制（`editingItemId`/`editingText`/`commitEdit`，给新物品命名用，`commitEdit` 即调 `updateItemName`）。按「顺既有机制、不自造平行件」，swipe「编辑」**复用行内编辑**——该行就地切成 InlineEditRow（出现即自动聚焦）、预填当前名——而非另弹 alert。更省、与新增命名完全一致、零新文案/无新埋点。`beginRename(itemId:)` 预填名字并切到编辑态；`commitEdit` 加判断：**已命名物品清空 = 取消还原（不删），仅从未命名的新行清空才删**，避免改名误删。

## 目标
让用户能改一条已在清单里的物品的名字——主要解决"手动加的物品打错字 / 想补充具体度"（如 `chrger → Phone charger`、`防晒 → 防晒 SPF50`）。现状只能删了重加，会连带丢数量/勾选/排序，是个真实小 papercut。

## 交互
- 物品行**左滑**，尾部出现两个 action（与行程停靠点 swipe 一致的范式）：
  - **编辑**（中性/蓝，前）→ 弹「重命名」alert。
  - **删除**（红，后）→ 现有逻辑不变。
- 「重命名」用**带 `TextField` 的 `.alert`**（非 sheet）：预填当前名字、Cancel / Save 两个按钮。Save 在「空白」或「与原名相同」时禁用。Save → `store.updateItemName(tripId:itemId:name:)`（trim 首尾空白）。
- **不做**：点名字直接进编辑（误触风险，用户明确否决）；不做整条 sheet 编辑（数量已可点徽标改、勾选已点行切换，只剩名字这一项，alert 足够、最克制）。

## 为什么 alert 不用 sheet
只改一个字段；带输入框的 alert 是 iOS 原生「重命名」标准范式（重命名文件夹/相册即此）；比 sheet 轻、不打断列表上下文。

## 集成点
- `ReorderableItemCollection`：新增 `onEdit: (UUID) -> Void`，在 `trailingSwipe(at:)` 的 `UISwipeActionsConfiguration` 里加一个 `UIContextualAction`（编辑），与现有 delete 并列。**完全镜像 `ItineraryReorderCollection` 已有的 `onEdit` 实现**，保持两个 collection 一致。
- `PackingListView`：传 `onEdit: { beginRename(itemId: $0) }`；新增 `@State renamingItem: (id: UUID, name: String)?`（或 id + draft 文本两个 state）驱动 `.alert`。

## 已知可接受的边界（不做防护）
`PackingItem.name` 同时被当作去重 / 状态恢复 key（`mergeItems` / `regenerateScenes`，小写匹配）。因此**改"推荐/预设来的物品"的名字、之后又回去改这趟的场景选择**，会让场景按 canonical 名重新加一条 → 重复。

- 影响面窄：只涉及"场景/预设来的"项（手动加的不受影响——本需求主场景）；且要"事后再改场景"（本就不常做）。
- **v1 列为已知可接受，不加防护**（不引入模糊匹配等脆弱逻辑）。真有反馈，根因修在 `regenerateScenes`（给 `PackingItem` 加来源标记按 id 而非 name 迁移状态），不在改名功能里。

## 边界与校验
- 空 / 纯空白名：禁用 Save（不允许把物品改成无名）。
- 与原名相同：禁用 Save（无操作）。
- 不查重名（与现有 `updateItemName` 一致；手动 + Add 本就允许重名，保持一致、不平添拦截）。
- 重命名**不动** quantity / isPacked / isAlert / sortOrder / section。

## 文案（9 语言，结构化 key，含 en）
- swipe 标题：复用行程停靠点 swipe「编辑」的现有 key（若有，如 `common.edit`）；没有则新增 `packing.item.rename.action`。
- alert 标题：`packing.item.rename.title`（如「重命名物品」）。
- 输入框 placeholder：复用现有「物品名」类 key 或新增 `packing.item.rename.placeholder`。
- 按钮：复用 `common.cancel` / `Save`（现有）。
- 中文全角标点。

## 埋点
新增 `CarryLogger.Event.itemRenamed`（与 action 同次接线，埋点闭环）；非错误事件。

## 数据 / 迁移
无。`PackingItem.name` 本就可变，`updateItemName` 已存在。

## 验收
- 手动加的物品左滑「编辑」→ 改名 → 持久化；数量/勾选/排序/分区不变。
- swipe 同时出现 编辑 + 删除；删除行为不变。
- 空白/同名时 Save 禁用。
- 暗色模式、9 语言、Mac Catalyst。
- （知会）改推荐项再改场景会重复——属已知边界，非 bug。
