# Auto Pack Review — Spec

> **Status: Pending** — AutoPackReviewView 尚未实现，当前 Auto Pack 流程直接进入 ItemPickerView

## 背景

现有 Auto Pack 流程：选场景 → 直接生成草稿行程 → 进入 PackingListView（isNewTrip=true）预览 → Save list。

问题：用户无法在预览阶段删除不需要的推荐物品，也无法补充遗漏的物品，只能退回重新选场景。

## 目标

在"场景选择"和"清单预览"之间插入一个新的审查步骤，让用户对推荐物品有完整的控制权，同时保持懒人路径足够短。

---

## 新流程

```
Auto Pack FAB
  → ScenePickerView（选场景）
    → [点击 Auto Pack]
      → AutoPackReviewView（推荐物品审查，全部默认勾选）✦ 新增
        → [点击 Preview List]
          → PackingListView（isNewTrip=true，只读预览）
            → [点击 Save list]
              → 行程物品清单（正式保存）
```

**懒人路径**：选完场景 → 不做任何操作 → 直接点 Preview List → Save list。两步即可。

---

## AutoPackReviewView 设计

### 数据来源
- 接收 `TripInfo` 和已选场景 keys
- 调用现有 `generatePackingSections(selectedScenes:tripDays:)` 获取推荐物品
- 所有推荐物品**默认勾选**

### 界面结构

**顶部**
- 标题：「Review your pack」（暂定）
- 副标题：「Based on your scenes, we've picked a starter list. Remove what you don't need or add more.」

**内容区（ScrollView）**
- 按分类分组展示推荐物品，每个分类可折叠/展开
- 每个物品行：勾选框 + 物品名
- 物品行右滑或点击勾选框可取消勾选（取消后变为半透明，可恢复）
- 底部有「+ Add more items」入口，点击弹出 ItemPickerView sheet（复用现有实现），选完后合并进当前列表

**底部固定栏**
- 显示当前勾选物品数量：「X items selected」
- 主按钮：「Preview List」（仅在有至少一个勾选物品时可点击）

### 交互细节
- 取消全部勾选时，Preview List 按钮 disabled，并提示「Select at least one item」
- 从 ItemPickerView 添加回来的物品追加到对应分类末尾，默认勾选
- 如果添加的物品分类不存在，新建分类放到末尾

---

## 对 ScenePickerView 的改动

`.autoPack` 分支的 `confirm()` 逻辑目前是：
1. 调用 `buildTrip()` 生成草稿并写入 store
2. 直接 push 到 `PackingListView`

改为：
1. 调用 `generatePackingSections()` 得到推荐 sections（**不写入 store**）
2. push 到 `AutoPackReviewView`，把 `TripInfo` 和推荐 sections 传入

草稿写入 store 的时机推迟到 AutoPackReviewView 点击「Preview List」时。

---

## 对 PackingListView 的改动

无需改动。`isNewTrip=true` 的只读预览逻辑保持不变。

---

## 涉及文件

| 文件 | 变更类型 |
|---|---|
| `Views/AutoPackReviewView.swift` | 新增 |
| `Views/ScenePickerView.swift` | 修改 `.autoPack` confirm 分支 |
| `Models/CreationRoute.swift`（或路由枚举所在文件） | 新增路由 case |
| `Localizable.xcstrings` | 新增文案 key |

---

## 暂不处理

- AutoPackReviewView 内直接删除整个分类
- 推荐物品的排序调整
- PackingListView（isNewTrip=true）内的编辑能力（保持现状）
