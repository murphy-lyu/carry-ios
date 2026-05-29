# Spec: Packing Live Activity

**Status**: Draft  
**Created**: 2026-05-29  
**Author**: Murphy  

---

## 一、背景与目标

用户在出发前打包行李时，需要在多个场景（翻衣柜、找充电器、整理箱子）之间来回，每次都需要解锁进 App 查看还缺什么。Live Activity 让打包进度常驻锁屏和 Dynamic Island，用户随时抬眼就能看到进度，减少反复开 App 的摩擦。

**不做**的事：
- 不把 Live Activity 当纯通知替代品（Apple 不鼓励，体验也有限）
- 不主动弹窗引导用户开启（用 Settings 开关代替）

---

## 二、完整用户场景

```
用户在设置里打开「锁屏打包进度」开关
        ↓
打包提醒时间到（NotificationManager 触发）
        ↓
App 收到提醒回调，自动在锁屏启动 Live Activity
锁屏显示：✈️ 去东京 · 2 天后出发 | 0 / 23 件
        ↓
用户打开 App，开始勾选物品
每次 isPacked 变更 → Activity.update() 更新进度
        ↓
全部勾选完：锁屏显示「打包完成 🎉 明天出发！」
        ↓
出发当天零点，或用户手动关闭，Activity 自动结束
```

**次要路径**：
- 用户开启开关后，主动进入打包清单界面，可手动点击「开启锁屏进度」按钮（非弹窗，嵌入在界面顶部）
- 用户可随时在锁屏长按 Activity → 关闭

---

## 三、数据模型

```swift
struct PackingActivityAttributes: ActivityAttributes {

    // 静态数据：Activity 启动后不变
    let tripName: String           // TripBundle.name
    let destinationCity: String    // TripBundle.destinationCity
    let departureDate: Date        // TripBundle.departureDate
    let totalItems: Int            // 所有 PackingItem 数量

    // 动态状态：每次打包勾选时更新
    struct ContentState: Codable, Hashable {
        let packedItems: Int       // 已勾选的 PackingItem 数量
        let isCompleted: Bool      // packedItems == totalItems
    }
}
```

---

## 四、生命周期

| 时机 | 操作 | 触发方 |
|------|------|--------|
| 打包提醒触发时 | `Activity.request(...)` 启动 | NotificationManager 回调 |
| 用户勾选/取消物品 | `Activity.update(...)` | TripStore / PackingListView |
| 全部物品打包完成 | `Activity.update(...)` → isCompleted = true | TripStore |
| 出发当天零点 | `Activity.end(...)` | NotificationManager 定时触发 |
| 用户手动关闭 | 系统处理（锁屏长按关闭）| 系统 |
| App 被卸载 / 行程删除 | `Activity.end(...)` | TripStore onDelete |

**注意**：
- Live Activity 最长存活 8 小时（系统限制），可请求延长至 12 小时
- 若用户未授权通知，须在 App 前台时通过 `ActivityAuthorizationInfo` 检查可用性后再启动

---

## 五、UI 规格

### 5.1 锁屏 / 灵动岛展开态（同一套布局）

```
┌─────────────────────────────────────────────┐
│  ✈️  去东京                    后天出发      │
│  ───────────────────────────────────────    │
│  ████████████░░░░░░░░   15 / 23 件          │
│  已打包                                     │
└─────────────────────────────────────────────┘

完成态：
┌─────────────────────────────────────────────┐
│  ✅  去东京                    明天出发！    │
│  ─────────────────────────────────────────  │
│  ████████████████████  23 / 23 件  🎉      │
│  打包完成，出发吧                            │
└─────────────────────────────────────────────┘
```

元素：
- 左上：目的地城市（加 ✈️ 图标）
- 右上：出发倒计时（今天 / 明天 / N 天后）
- 中：LinearProgressView，颜色用 `.tint(.blue)` 或品牌色
- 下：`已打包 X / Y 件`，完成后改为 `打包完成，出发吧 🎉`

### 5.2 Dynamic Island 紧凑态（Leading + Trailing）

```
Leading:  ✈️ 图标
Trailing: 65%  （进度百分比文字）
```

### 5.3 Dynamic Island 最小态（Minimal）

```
✈️  （仅图标）
```

---

## 六、Settings 开关

在 Settings → General section 末尾新增一行 Toggle：

```
锁屏打包进度          ●──  (开/关)
```

- Key：`UserDefaults` `liveActivityPackingEnabled`，默认 `false`
- 开关关闭时：不启动 Live Activity，也不影响通知
- 开关开启时：下次打包提醒触发时自动启动（已在打包中的行程：进入打包界面时可手动激活）
- 文案 key：`settings.liveactivity.packing`（需补全 9 种语言）

---

## 七、技术实现步骤

1. **Info.plist** 添加 `NSSupportsLiveActivities = YES`
2. **新建 Widget Extension target**（File → New → Target → Widget Extension，勾选 Include Live Activity）
3. **定义 `PackingActivityAttributes`**（新文件 `PackingActivityAttributes.swift`，需加入 App target 和 Widget Extension target）
4. **`PackingLiveActivityView.swift`**（Widget Extension 内，实现锁屏 / 展开 / 紧凑 / 最小四种布局）
5. **`LiveActivityManager.swift`**（App target，封装 start / update / end 逻辑）
6. **接入 NotificationManager**：打包提醒回调时调用 `LiveActivityManager.start(...)`
7. **接入 TripStore / PackingListView**：每次 `isPacked` 变更时调用 `LiveActivityManager.update(...)`
8. **Settings 开关**：新增 Toggle，读写 UserDefaults

---

## 八、待确认问题

- [ ] Widget Extension 的 Bundle ID 命名规范（建议 `com.murphy.carry.PackingWidget`）
- [ ] 倒计时文案：「今天出发」「明天出发」「3 天后出发」——是否需要国际化日期表达方式做额外适配
- [ ] 打包提醒可能设置多个时间，以哪一个为准触发 Live Activity？（建议：最近一个未触发的提醒）
- [ ] 行程有多个时，同时只允许一个 Live Activity（系统限制），如何处理多行程并发？（建议：以最近出发的行程为准）

---

## 九、不在本期做的事

- Push-to-Start（后台远程触发 Live Activity）
- 航班动态联动
- Apple Watch 镜像
