# 我的物品库：自定义分类的复用 / 重命名 / 删除

Status: Confirmed, implementing
Date: 2026-06-18

## 背景与问题
`MyItem.category` 是自由字符串，没有独立「分类」实体——自定义分类即用户在物品上填写的 category 文本。
加自定义物品的编辑器（`ItemPickerMyItemEditorView`）的分类选择只列「None + 内置目录分类 + 自定义（输入框）」，
**不列用户此前建过的自定义分类**，导致每次都要重输（如反复输入「宝宝」）。且无任何「分类级」的删除/重命名 →
「只能创建不能删除」体验不完整。

## 目标
1. **复用**：编辑器选择分类时，列出用户在当前 collection 已建的自定义分类，可直接选。
2. **重命名**：把某自定义分类下所有物品的 category 批量改名。
3. **删除**：删除某自定义分类——**只清空其物品的 category（物品保留，变为未分类/None）**，不删物品。
   （用户决策：保留物品；单件删除已有 swipe 删除可用。）

## 数据语义
分类派生自物品，无独立实体：
- 「已建自定义分类」= 当前 collection 内 `myItems` 去重的 category，且非空、不属于内置目录分类。
- 重命名 = 该 collection 内所有 `category == old` 的物品改为 `new`。
- 删除 = 该 collection 内所有 `category == name` 的物品 `category = ""`（→ 未分类）。
- 空分类不持久化（无物品引用即不存在），故无需「空分类清理」。

## 落点（UX）
分类的「选择 + 复用 + 管理」合并到**同一处**（克制、就地）：把编辑器里原生 `Picker(.navigationLink)`
换成自定义的 `MyItemCategoryPickerView`（pushed List）：
- 「你的分类」组：列已建自定义分类，点选即用；行 swipe → 重命名（alert + TextField）/ 删除（带确认）。
- 「预设」组：None + 内置目录分类，点选即用。
- 「新建分类…」：回到编辑器的自定义输入框（沿用原 sentinel 流程）。

## Store 新增
- `customCategoryNames(in collection: String) -> [String]`
- `renameMyItemCategory(from old: String, to new: String, in collection: String)`
- `deleteMyItemCategory(_ name: String, in collection: String)`
均沿用既有 `mutate item.category + save()` 模式。

## 本地化
新增 key（9 语言）：分组标题「你的分类」、「新建分类…」、重命名标题、删除确认（含 `%@` 分类名）。
复用既有：`myitems.category.none`、`myitems.category.custom*`、`common.cancel`、`common.done`。
