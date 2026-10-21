# App Store 提交指南

整理首次上线前必须完成的合规材料，包含隐私政策和 Privacy Nutrition Labels 的具体操作说明。

首次整理：2026-05-27

---

## 1. 隐私政策 URL

### 为什么必须有

App Store Connect 提交审核时「隐私政策 URL」为必填项，缺少则无法提交。

### 操作步骤

1. **起草文本** — 参见下方「隐私政策内容要点」
2. **托管到公开 URL**（选一种）：
   - GitHub Pages（免费，推荐）：新建一个 public repo，开启 Pages，把 HTML/Markdown 放进去
   - Notion 公开页面：在 Notion 新建页面 → Share → Publish to web → 复制链接
   - 个人网站/域名（最专业）
3. **填入 App Store Connect**：App → App Information → Privacy Policy URL

### 隐私政策内容要点（针对 Carry）

隐私政策必须覆盖以下几点：

**数据收集**
- **位置数据**：用于目的地城市解析（CLGeocoder）和地图显示（MapKit）。数据仅在设备本地处理，不上传服务器，不与第三方共享。
- **本地通知**：用于打包提醒。通知内容仅存储在设备本地，不收集用户通知数据。

**第三方服务**
- **Apple StoreKit**：内购功能由 Apple 处理，支付数据由 Apple 收集和管理，开发者不接触支付信息。参见 [Apple 隐私政策](https://www.apple.com/privacy/)。
- **Apple MapKit / CLGeocoder**：地图和地理编码服务由 Apple 提供。

**数据存储与安全**
- 行程、物品清单保存在设备本地，并通过用户自己的 iCloud 私有 CloudKit 数据库在其设备间同步；开发者无法读取这些私有数据。
- 用户可以导出本地备份文件。航班查询会把航班号和日期发送到 Carry 的查询代理，地点、天气及地图查询会把完成请求所需的查询词或坐标发送给对应服务商；这些查询不与 Carry 账号或广告标识关联。

**用户权利**
- 面向 EU 用户（GDPR）：用户可随时在 App 内删除所有数据（设置 → 恢复数据），或直接卸载 App，所有本地数据随之清除。
- 面向加州用户（CCPA）：App 不出售用户数据，不与第三方共享用于广告目的的个人数据。

**联系方式**
- 提供一个可用的联系邮箱，供用户就隐私问题联系开发者。

---

## 2. Privacy Nutrition Labels

### 在哪里填

App Store Connect → App → App Privacy → 「Get Started」或「Edit」

### Carry 的具体选项（逐项）

| 数据类型 | 是否收集 | 选项 |
|--------|--------|------|
| **位置 - 精确位置** | ✅ 是 | 用途：App Functionality；与身份关联：否；追踪：否 |
| **位置 - 粗略位置** | ✅ 是 | 用途：App Functionality；与身份关联：否；追踪：否 |
| **购买记录** | ⚠️ Apple 处理 | StoreKit 内购由 Apple 处理，**开发者不收集**，此项选「否」 |
| **标识符（Device ID）** | ❌ 否 | 未使用任何设备标识符 API |
| **崩溃数据** | ❌ 否 | 未接入第三方崩溃监控（仅 Xcode Organizer，Apple 侧收集） |
| **使用数据 / 分析** | ❌ 否 | 无第三方分析 SDK |
| **诊断数据** | ❌ 否 | — |
| **广告数据** | ❌ 否 | 无广告 |
| **联系信息** | ❌ 否 | — |
| **财务信息** | ❌ 否 | — |

**最终申报结果预计：**「我们收集位置数据，用于 App 功能，不与身份关联，不用于追踪。」其余均不收集。

### 注意事项

- StoreKit 内购：Apple 在其自身的隐私标签中披露支付数据，开发者侧不需要重复申报。
- 位置权限：Carry 使用 `When In Use` 权限，Info.plist 里的 `NSLocationWhenInUseUsageDescription` 描述需与隐私标签一致。
- 本地通知（UNUserNotificationCenter）：不产生任何数据上传，无需在 Nutrition Labels 中申报。

---

## 3. TestFlight（进行中）

**当前状态（2026-10-21 本地记录）：** App Store Connect 应用记录已创建，build `1.0 (1)` 与 `1.0 (2)` 已上传并处理；内部测试组和测试资料已配置。下一次上传使用 build `1.0 (3)`。

**操作步骤：**
1. Xcode → Product → Archive（使用 Release scheme）
2. Window → Organizer → Distribute App → TestFlight & App Store
3. 上传成功后在 App Store Connect → TestFlight 里找到构建版本
4. 内部测试员安装 TestFlight App 后测试；外部测试需为构建提交 Beta App Review
5. 重点测试路径：创建行程 → 添加物品 → Auto Pack → 打包勾选 → iCloud 同步 → Widget / Live Activity → 内购 → 通知

---

*完成隐私政策 URL 并填好 Nutrition Labels 后，在 [release-checklist.md](release-checklist.md) 对应项打勾。*
