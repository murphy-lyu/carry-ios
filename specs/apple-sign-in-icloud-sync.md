# iCloud 同步与可选 Apple 登录

> **Status: Phase B 已接入，待双机验收；Apple 登录明确延后** — 2026-09-25

> **2026-10-25 方向调整**：CloudKit Production 结构已部署并核对；双设备同步尚未验收。用户明确要求长期支持手机关闭时的 AI 操作，并同意适合时使用 Apple ID 登录，见 `carry-cloud-and-ai.md`。新方案选择可选 Carry 账户、原生/网页 Apple 登录为首选，独立账户数据服务的选型与实现仍在验证；下文“不自建后端/不做账号”的旧决定只描述原 iCloud 方案，不能作为新方案已被否决或已被实现的证据。新账户删除仅处理其明确归属的数据，不沿用旧 Phase A 中自动清除整个 iCloud 私有库的设想。

## 已确认的产品决策（来自需求讨论）

1. 首版只启用 **CloudKit 私有库同步**，不加入 App 内“使用 Apple 登录”。
2. 不登录 App 也能完整使用；同步使用设备本身的 iCloud 账号。
3. 不自建后端，不做邮箱登录或多人协作。

## 关键架构事实（决定怎么建）

> **跨设备同步 = CloudKit + 设备 iCloud 账号，不等于 App 的 Apple 登录。** 两块松耦合：

- **iCloud 同步**：只要设备登录了 iCloud，打开 SwiftData 的 CloudKit 配置即可在用户**自己的设备间**私有同步，**不依赖**我们的 Apple 登录。
- **Apple 登录**：给 App 内的「身份」（名字/邮箱/头像、登出）。在已有 iCloud 同步前提下，它是身份展示 + 未来接后端的入口，**不是**同步的必要条件。

因此本特性拆成两条可独立推进的线：**(A) Apple 登录身份**、**(B) iCloud 同步**。

## Schema 兼容性核实结论（已查实，非推测）

现有 `@Model`（`TripBundle` / `PackingSection` / `PackingItem` / `MyItem` / `ItineraryDay` / `ItineraryStop`）**已满足 SwiftData + CloudKit 硬约束**：
- 每个标量属性都有默认值（`= ""` / `= 0` / `= Data()` / `= false` / `= []`）✅
- 关系全部可选 + 显式 `inverse` + `.cascade` ✅
- 无任何 `@Attribute(.unique)` ✅

→ 开 CloudKit 不需要 schema 迁移。Apple 当前文档明确不支持的是 `.deny`、唯一约束和非可选关系；`.cascade` 是 SwiftData 支持的删除规则，保留现有关系定义。

## 外部依赖状态

1. [x] iCloud → CloudKit，容器 `iCloud.app.nevestudio.carry`
2. [x] Background Modes → Remote notifications
3. [x] Team `25RAM7275Z` 的有效 provisioning profile
4. [x] Release 真机构建、签名、安装
5. [x] 真机冷启动成功，未触发 in-memory fallback
6. [ ] 双机同步、删除重装恢复、Production schema 部署

## App Store 合规

- **账号删除（Guideline 5.1.1(v)）**：一旦有「账号」，必须在 App 内提供**删除账号**入口。本特性的删除 = 撤销 Apple 凭证 + 清本地凭证 + 清 CloudKit 私有库数据。必须实现，否则审核被拒。
- 隐私清单 / 隐私政策：若收集邮箱（即便私密转发），更新 `PrivacyInfo.xcprivacy` 与隐私政策的数据收集声明。
- Apple 登录拿到的 name/email **只在首次授权时返回一次**，必须当场持久化（Keychain），不能依赖后续再取。

## 实现分期

### Phase A — Apple 登录身份（首版不做）
1. `AccountStore: ObservableObject`（注入 environment）：
   - `signInState`（`.signedOut` / `.signedIn(profile)`）、`displayName`、`email`、`userIdentifier`
   - Keychain 存 `userIdentifier` + 首次返回的 name/email
   - 启动时 `ASAuthorizationAppleIDProvider.getCredentialState(forUserID:)` 校验凭证是否被撤销 → 撤销则回落 `.signedOut`
   - `signOut()`：清 Keychain + 状态归零（本地数据保留）
2. UI：
   - 登录入口放 **设置页**（`SettingsView`）顶部一个账号区：未登录显示 `SignInWithAppleButton`；已登录显示名字/邮箱 + 「退出登录」+「删除账号」。
   - **首页右上齿轮**：未登录 = 齿轮（现状，已做）；已登录 = 头像（Apple 不提供头像图，用**姓名首字母 monogram** 圆形徽标，烟蓝底白字，或用户后续自定义）。切换由 `AccountStore.signInState` 驱动——此时才把头像分支写成活代码。
3. 文案：所有新增 UI 文案进 `Localizable.xcstrings`，补全 9 种语言。
4. 埋点：登录成功/失败/登出/删除账号 Event（按 `CarryLogger` 闭环规范，定义即接线）。

### Phase B — iCloud 同步（已接入，待验收）
1. [x] `CarryApp.container` 使用 `ModelConfiguration(..., cloudKitDatabase: .automatic)`；in-memory fallback 显式使用 `.none`。
2. [x] `Carry.entitlements` 使用 `iCloud.app.nevestudio.carry`；Info.plist 开启 Remote notifications。
3. 真机验证：两台同 iCloud 账号设备增删行程/物品 → 双向同步；无 iCloud 账号设备 → 纯本地正常工作（不崩、不报错）。
4. 首次开启 CloudKit 后，Development → Production schema 部署（CloudKit Dashboard）必须在上架前完成，否则线上用户同步失败。

### Phase C — 账号删除（仅未来加入 Apple 登录时需要）
- 删除流程：二次确认 → 清 CloudKit 私有库（删本地所有 `@Model` 实例并等待同步推送删除）+ 清 Keychain + 状态归零。

## 明确不做（本特性边界）
- 邮箱/密码登录、自建后端、多人协作、服务端账号体系 —— 留到将来真有需求。
- 头像上传/自定义图（先用 monogram，够用且零依赖）。

## 风险与注意
- CloudKit 同步是异步、最终一致，不能假设即时；UI 不得阻塞等待同步。
- `getCredentialState` 是异步网络调用，启动时不能阻塞主流程，登录态先用本地缓存乐观显示、回调再校正。
- in-memory fallback（DB 初始化失败时）下 CloudKit 不可用，需保证此路径不挂 CloudKit 配置。
