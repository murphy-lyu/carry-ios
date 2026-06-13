# Apple Sign In + iCloud 同步（账号身份与跨设备同步）

> **Status: Draft（待确认后实现）** — 本 spec 等用户确认范围后再开工。

## 已确认的产品决策（来自需求讨论）

1. **范围 = 身份 + iCloud 同步（中档）**：做 Apple 登录拿到身份（名字/邮箱/头像），并用 **CloudKit 私有库**把行程/打包清单跨设备同步。**不**自建后端、**不**做邮箱登录（那是更重的独立特性，留到以后真有需求再说）。
2. **登录可选**：不登录也能完整使用 App。登录只是「锦上添花」——展示身份、为将来铺路。**禁止**用登录门槛挡住任何现有功能。

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

→ **开 CloudKit 不需要痛苦的 schema 迁移**。唯一要确认的细节：CloudKit 不支持 `.cascade` 自动删除（它只支持 `.nullify`），SwiftData 在 CloudKit 模式下会把 cascade 当 nullify 处理 → 删除 `TripBundle` 后子记录需由我们显式删（`TripStore` 现有删除逻辑已是显式遍历删，需复核确认不依赖 cascade 兜底）。

## 外部依赖（用户必须在 Xcode / Apple Developer 完成，我无法代劳）

1. **Signing & Capabilities** 添加：
   - **Sign in with Apple**
   - **iCloud → CloudKit**（新建/选择一个 CloudKit container，如 `iCloud.com.murphy.carry`）
   - **Background Modes → Remote notifications**（CloudKit 静默推送拉取远端变更）
2. 上述需有效 provisioning（付费开发者账号，已具备）。
3. entitlements 文件里的 key 我可以加，但 capability 勾选 + 重签必须在 Xcode 内点。

## App Store 合规

- **账号删除（Guideline 5.1.1(v)）**：一旦有「账号」，必须在 App 内提供**删除账号**入口。本特性的删除 = 撤销 Apple 凭证 + 清本地凭证 + 清 CloudKit 私有库数据。必须实现，否则审核被拒。
- 隐私清单 / 隐私政策：若收集邮箱（即便私密转发），更新 `PrivacyInfo.xcprivacy` 与隐私政策的数据收集声明。
- Apple 登录拿到的 name/email **只在首次授权时返回一次**，必须当场持久化（Keychain），不能依赖后续再取。

## 实现分期

### Phase A — Apple 登录身份（自包含，先做，立即可见效果）
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

### Phase B — iCloud 同步（依赖用户先开 capability）
1. `CarryApp.container`：`ModelConfiguration` 加 `cloudKitDatabase: .private("iCloud.com.murphy.carry")`（或 `.automatic`）。in-memory fallback 分支不动。
2. 复核 `TripStore` 删除路径不依赖 cascade 兜底（CloudKit 下 cascade 退化为 nullify）。
3. 真机验证：两台同 iCloud 账号设备增删行程/物品 → 双向同步；无 iCloud 账号设备 → 纯本地正常工作（不崩、不报错）。
4. 首次开启 CloudKit 后，Development → Production schema 部署（CloudKit Dashboard）必须在上架前完成，否则线上用户同步失败。

### Phase C — 账号删除（合规，A/B 完成后）
- 删除流程：二次确认 → 清 CloudKit 私有库（删本地所有 `@Model` 实例并等待同步推送删除）+ 清 Keychain + 状态归零。

## 明确不做（本特性边界）
- 邮箱/密码登录、自建后端、多人协作、服务端账号体系 —— 留到将来真有需求。
- 头像上传/自定义图（先用 monogram，够用且零依赖）。

## 风险与注意
- CloudKit 同步是异步、最终一致，不能假设即时；UI 不得阻塞等待同步。
- `getCredentialState` 是异步网络调用，启动时不能阻塞主流程，登录态先用本地缓存乐观显示、回调再校正。
- in-memory fallback（DB 初始化失败时）下 CloudKit 不可用，需保证此路径不挂 CloudKit 配置。
