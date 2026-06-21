# 从 Tripsy 导入（Import from Tripsy）

> **Status: Draft（待评审 → 实现）** — 核心转换引擎已在离线 Python 原型（`~/Downloads/tripsy_inspect/tripsy_to_carry.py`）上跑通并用真实数据（16 行程 / 36 地点 / 15 交通 / 10 住宿 / 1 图片）逐项验证。本 spec 把已验证的映射/转换/架构约束固化，指导 Swift 在 App 内落地。
>
> **已验证的关键事实**（实现时不必再求证）：
> 1. Tripsy 导出 = Core Data SQLite（`Tripsy.sqlite` + `-wal`/`-shm` + `Documents/` 图片）打包的 zip。
> 2. 国内坐标 Tripsy 存 **GCJ-02**，与 Carry 内部约定一致 → **零转换直接拷贝**（已用呼和浩特地标实测）。
> 3. Carry `spanDays = isDateless ? 1 : days+1`；`syncItineraryDays()` 强制天数==spanDays、多余天会被删并把地点甩到最后一天 → 决定了「未排期点」与「天数字段」的处理方式（见下）。

## 动机

Tripsy 是 Carry 行程规划方向的主要参考产品，也是目标用户（有旅行习惯、追求品质）当前的存量阵地。提供"一键从 Tripsy 迁移历史行程"是一个**自然的获客/迁移钩子**：精准命中已经在认真记录旅行的人。核心转换逻辑已现成且无损，落地成本主要在 Swift 移植 + 导入 UI。

## 范围与非目标

**做**：
- App 内入口：用户选择 Tripsy 导出的 zip（或其内的 `.sqlite`），Carry 原生解析 → 预览 → 合并导入。
- 全程在设备上完成，不依赖电脑/脚本/中间文件。
- 行程、地点、交通、住宿、图片附件的迁移。

**不做（非目标）**：
- 不做 Tripsy 账号登录/云端拉取（只吃用户自己导出的离线 zip；Tripsy 那边的"导出全部数据"是用户手动一步，避不开）。
- 不迁移 Tripsy 的协作者/Guest、独立记账（TripExpense）、日历事件 id、行程背景图 URL（见"缺口"）。
- 不做反向（Carry → Tripsy）。
- 不在本期补齐 Carry 行程规划自身的功能缺口（导入会先暴露它们，属预期，见"缺口与降级"）。

## 用户流程

1. **Tripsy 侧**：用户在 Tripsy「设置 → 导出全部数据」生成 zip（系统分享面板）。
2. **进入 Carry 导入**：
   - **一期（本 spec 范围）**：Carry 内主动入口——设置 → 数据与备份 → **「从 Tripsy 导入」**（独立于现有「导入备份」入口）→ `.fileImporter` 选 zip。用户需先把 Tripsy 导出的 zip 存到「文件」App。
   - **二期**：系统分享面板接收——Tripsy 导出时直接分享给 Carry（注册 zip / Tripsy 导出 UTType），省去"存文件再翻找"。
3. **解析 + 预览**：Carry 解 zip、读 SQLite，弹**导入预览**：
   - "发现 N 个行程"，列出每个行程名 + 日期 + 「X 地点 · Y 交通 · Z 住宿」摘要。
   - 默认全选，可逐个取消勾选。
   - 明确提示**合并语义**：「将新增到你现有行程，不会覆盖已有数据」。
4. **确认导入** → 进度 → 结果页：「成功导入 N 个行程」，可点击跳转到其中一个。
5. 重复导入同一份 zip → 已存在的行程（确定性 UUID 命中）自动跳过，不产生重复。

## 数据来源：Tripsy 导出格式

zip 内容：
- `Tripsy.sqlite`（+ `Tripsy.sqlite-wal` / `-shm`）：Core Data store。**必须连 `-wal` 一起读**，否则最近改动可能只在 WAL 里、读到旧值。
- `Documents/`：图片附件原文件，文件名形如 `<前缀>-<原名或uuid>.jpeg`。

### 相关表（Z_PRIMARYKEY 实体名 → 表）
- `ZTRIP`(Trip)、`ZACTIVITY`(Activity 地点/POI)、`ZTRANSPORTATION`、`ZHOSTING`(住宿)、`ZGENERALACTIVITY`(连接表)、`ZDOCUMENT`、`ZGEOCODEDLOCATION`、`ZTRIPEXPENSE`、`ZTRIPGUEST`、`ZCUSTOMCATEGORY`。
- **`ZGENERALACTIVITY` 是行程归属 + 日期的唯一真源**：每行 `ZTRIP`(行程PK) + 三选一的 `ZACTIVITY`/`ZTRANSPORTATION`/`ZHOSTING`(条目PK) + `ZDATE`。各条目表本身**没有指向 Trip 的外键**，必须经此连接表关联。`ZTRIP` 为空的行是孤儿（无所属行程），跳过。
- 文档挂载：`Z_1DOCUMENTS(Z_1ACTIVITIES1=activity PK, Z_3DOCUMENTS=document PK)`，本数据中仅 Activity 挂文档。
- Core Data 时间戳 = 距 `2001-01-01 00:00:00 UTC` 的秒（Unix = 值 + 978307200）。

## 解析方案（on-device）

- **解压**：zip → 临时目录。iOS 可用 `Foundation` 的 `FileManager`/`NSFileCoordinator` + 第三方轻量 zip（或 Apple `AppleArchive`）。优先无第三方依赖方案；若引入 zip 库须隔离。
- **读 SQLite**：用系统自带 `sqlite3` C API（或轻封装 GRDB，但避免重依赖）。**只读**，开启 WAL 模式读取。不要尝试用 Core Data 栈挂载 Tripsy 的 store（需要其 `.momd` 模型，脆弱）；直接按表名/列名读裸 SQLite 更稳。
- **容错**：所有列按"可能为 NULL/缺列"处理（`columnExists` 检查 + 默认值），见"Schema 兼容策略"。

## 实体映射

| Tripsy | Carry | 备注 |
|---|---|---|
| `ZTRIP` | `TripBundle` | |
| `ZACTIVITY` | `ItineraryStop`（挂 `ItineraryDay`） | |
| `ZTRANSPORTATION` | `TransportSegment` | |
| `ZHOSTING` | `LodgingStay` | |
| `ZGENERALACTIVITY` | —（用于算天序 + 行程归属） | |
| `ZDOCUMENT` | `ItineraryAttachment` | link / photo / file |
| `ZTRIPEXPENSE` / `ZTRIPGUEST` / `ZCUSTOMCATEGORY` | 丢弃 | Carry 无对应 |

### 字段级映射（要点）

**Trip → TripBundle**
- `id` = 确定性 UUID（见"导入语义"）；`name` = `ZNAME`；`isDateless` = `!ZHASDATES`。
- `destinationCity`：`ZNAME` 含 `•`/`·` 时取分隔后末段（"新疆•伊犁"→"伊犁"），否则用整名。
- `days` = `spanDays - 1`（见"天数 off-by-one"）。
- `departureDate` = 行程起始（dated）/ 占位（dateless）；`createdAt` = `ZINTERNALCREATEDAT`。
- `countryCode`：按行程坐标就近匹配 `ZGEOCODEDLOCATION.ZCOUNTRYCODE`；兜底地址含"中国"→`CN`；匹配不到留空（海外不强标，地图不点亮可接受）。
- `latitude/longitude`：取首个住宿/地点坐标，兜底用交通到达点坐标。
- `selectedSceneKeys`/`dismissedSurpriseNames`=[]；`sections`=[]（不迁移打包清单——Tripsy 无此概念）；`reminderConfigData`=空。

**Activity → ItineraryStop**
- `name`/`latitude`/`longitude`/`address`/`phone` 直拷；`category` 见映射表。
- `plannedStartMinutes` = 当地起始分钟（无时间 → -1）；`stayMinutes` = `ZENDS-ZSTARTS`（分钟，无则 0）。
- `costAmount`=`ZPRICE`、`costCurrencyCode`=`ZCURRENCY`（仅价>0 时写）。
- `timeZoneId`=`ZTIMEZONE`（经 `TimeZoneCanonicalizer.canonical()`，大陆别名归北京）。
- `note` 汇入：`ZNOTES` + `ZDESCRIPTIONTEXT` + 「预订号: `ZRESERVATIONCODE`」+「网址: `ZWEBSITE`」（Carry stop 无这些专属字段）。

**Transportation → TransportSegment**
- `mode`：`airplane→flight`、`car→carRental`、`roadtrip→other`、`train→train`、`bus→bus`、`ferry→ferry`，默认 `other`。
- `carrier`=`ZCOMPANY`；`number`=`ZTRANSPORTNUMBER`。
- 机场：`fromCode/toCode` = `ZDEPARTUREDESCRIPTION`/`ZARRIVALDESCRIPTION`（IATA 三字码，仅 airplane）；`fromName/toName` 先用 IATA 码占位（Tripsy 不存机场全名；Carry 航班刷新可后补全名/本地化，见 [[itinerary-flight-name-localization]]）。
- 坐标/航站楼：`from/toLatitude/Longitude`、`from/toTerminal` 直拷；`from/toAddress`=`ZDEPARTURE/ARRIVALADDRESS`。
- 时间：`departDayOrder/departLocalMinutes`、`arriveDayOrder/arriveLocalMinutes` 各按出发/到达**自身时区**折算（跨天航班两个 dayOrder 可不同）。
- `seat`=`ZSEATNUMBER`；`confirmationCode`=`ZRESERVATIONCODE`；`distanceMeters`=`ZDISTANCEINMETERS`；`vehicleModel`=`ZVEHICLEDESCRIPTION`；`phone`=`ZPHONE`。
- `note` 汇入：`ZNOTES` +「舱位: `ZSEATCLASS`」（Tripsy 是舱位字母码 S/K，**不映射** Carry 的 `cabinClass` 枚举）+「登机口/到达登机口」+「网址」。
- 交通段挂在**出发那天**（`departDayOrder`）。

**Hosting → LodgingStay**
- `name`/`address`/`latitude`/`longitude`/`phone`/`confirmationCode` 直拷。
- `checkInDayOrder` = 入住当地日期的天序；`nights` = `ZENDS-ZSTARTS` 的天数（≥1）；`checkInMinutes`/`checkOutMinutes` = 当地分钟（无则 -1）。
- `timeZoneId`=`ZTIMEZONE`（经 canonical）；`cost` 同上。
- `note` 汇入：`ZNOTES` + `ZDESCRIPTIONTEXT` +「房型/房号: `ZROOMTYPE`/`ZROOMNUMBER`」+「网址」。

**Document → ItineraryAttachment**（仅挂 Activity）
- `ZFILETYPE=url` 或仅有 URL → `kind=.link`，`urlString`=`ZURL`，`displayName`=`ZTITLE`。
- 本地图片（`ZLOCALPATH` 指向 `Documents/<前缀>-…`）→ `kind=.photo`/`.file`，按前缀在 `Documents/` 匹配文件，**字节随备份写回沙盒**（对应 Carry 的 `AttachmentStore` + `CarryBackup.attachmentFiles` 约定，见 [[itinerary-attachments]]）。
- 注意 Tripsy 的 S3 `ZURL` 是带签名的**过期**链接（`Expires=…`），link 型可保留 URL 但可能已失效；本地有原图的优先走本地字节。

## 关键转换规则

### 1. 时间：绝对时间戳 + 时区 → 天序 + 当地分钟
Tripsy 存绝对 UTC 时间戳 + 每条目 IANA 时区；Carry 存"相对 day0 的天序 + 当地分钟"。
- **dated 行程**：`day0` = `local_date(ZTRIP.ZSTARTS, 默认时区)`（Tripsy 把行程起止存为"当地午夜的 UTC 表示"，须按默认时区取本地日期，**勿用 UTC 直接 date()**——会差一天）。每条目按**自身时区**取本地日期 → `dayOrder = (本地日期 - day0).days`，clamp 到 `[0, span-1]`。**不做整体平移**（day0 固定）。
- **dateless 行程**：Carry 恒定 1 天，所有条目落 `dayOrder=0`。

### 2. 天数 off-by-one（必须对）
Carry `spanDays = days + 1`。若把"天数"直接写进 `days`，**每个有日期行程都会多出假的一天**（6 天行程显示成 7 天、末尾空白）。正确：`days = span - 1`，其中 `span = max(行程日期跨度, 已排期条目最大天序+1)`。dateless：`days = 0`。

### 3. 未排期收藏点（无 `ZSTARTS` 且无 `ZDATE`）
Tripsy 的"想去/未排期"地点。Carry **没有未排期暂存桶**，且 dated 行程**不能加无日期的尾巴天**（`syncItineraryDays()` 会删掉它、把地点甩到最后一天）。
- **策略**：未排期点按**地理位置归到"最近的已排期地点"那一天**（它们多是某已排景点周边的子景点）。
- **兜底**：无坐标、或该行程无任何已排期锚点 → 放最后一天（dated）/ 唯一天（dateless）。
- 这些点 `plannedStartMinutes = -1`，在所在天显示为"无时间"项。

### 4. 坐标
国内 GCJ-02 直接拷贝（已实测）；海外 WGS-84 直接拷贝。**不做任何偏移转换**。

### 5. 类目映射
- Activity→StopCategory：`tour→sightseeing`、`restaurant/cafe→food`、`museum/park→sightseeing`、`parking/general→other`，默认 `other`。
- 未知值经 `StopCategory(rawValueOrOther:)` / `TransportMode(rawValueOrOther:)` 自然落 `other`。

## 导入语义（合并，非覆盖）

- 走 Carry 现成的**合并**通道（`DataBackupManager.mergeFromData` / `performMerge`）：按 UUID 去重，**只新增本地不存在的行程，绝不覆盖已有数据**。
- **确定性 UUID**：所有实体 id 用 `uuid5(固定命名空间, "类型|Tripsy内部标识")` 生成（行程用 `ZINTERNALIDENTIFIER`，无则 PK）。→ **同一份 zip 重复导入幂等**（第二次全部命中已存在 → 跳过）。
- 不与 Carry 自身 UUID 冲突（不同命名空间/来源）。
- 实现可二选一：
  - **A（推荐，复用最多）**：解析层产出 `CarryBackup` 值对象（in-memory），直接喂给 `performMerge`。零新增还原逻辑、自动获得附件字节写回。
  - B：解析层直接 `context.insert` 各 `@Model`。更直接但要重写一遍还原/附件逻辑，易漏（cost 快照、附件字节、`TimeZoneCanonicalizer` 等四处闭环）。**选 A**。

## 缺口与降级（诚实告知用户）

导入预览页用一行小字说明"以下不会迁移"，避免用户以为丢数据：
- **打包清单**：Tripsy 无此概念，不迁移（Carry 强项，用户自行新建）。
- **独立记账**（TripExpense）：Carry 只有"按条目记费"，无独立账本 → 丢弃（条目自带的 `ZPRICE` 已迁为条目 cost）。
- **协作者/Guest**、日历事件 id、行程背景图 URL、Activity 网站/营业时间、住宿房型号（已汇入 note）。
- **机场全名**：仅迁 IATA 码 + 坐标，全名待 Carry 航班刷新补。
- Carry 行程规划自身尚在建设 → 导入后可能暴露"某类信息 Carry 还没地方显示"。属预期，按 Carry 现有模型能装多少装多少，其余进 note 不丢。

## Schema 兼容策略（长期维护点）

读竞品 Core Data 库的**固有风险**：Tripsy 改版可能增删列/改语义，导致解析失效。
- **防御式读取**：先查 `PRAGMA table_info` 拿到实际列集合；每列读取走 `value(column:) ?? 默认`，缺列不崩、降级为空。
- **版本探测**：可读 `Z_METADATA`/`Z_MODELCACHE` 记录 Tripsy 模型版本，存日志；不作硬门槛（避免 Tripsy 小改版就拒绝导入）。
- **整体容错**：单个行程/条目解析异常 → 跳过该条 + 计数，不中断整次导入；结果页报"成功 N，跳过 M"。
- **不假设固定 PK**：一切关联走列名 join，不写死 `Z_ENT`/PK 数值。

## 错误处理与边界

- 选错文件（非 Tripsy zip / 损坏 / 无 `Tripsy.sqlite`）→ 明确错误文案，不崩。
- 空库（0 行程）→ 友好提示"未发现可导入的行程"。
- 大库 / 大量图片 → 解析在后台线程，主线程只读 `@Model`（遵循 Carry 通知/备份的"主线程读模型、回调碰值类型"约定）。
- 临时解压目录用完即清。

## 文案 / 本地化

- 所有面向用户文案进 `Localizable.xcstrings`，9 语言齐全；中文全角标点。
- 新增 key（示例）：`settings.data.import_tripsy`、`tripsy_import.preview.title`、`tripsy_import.preview.summary`(X 地点·Y 交通·Z 住宿)、`tripsy_import.merge_note`、`tripsy_import.skipped_note`(不迁移项说明)、`tripsy_import.result`、各错误态。

## 埋点（CarryLogger）

- 新增 Event 并同次接线（遵守"先定义后接线=死代码"铁律）：`tripsyImportStarted`、`tripsyImportSucceeded`(trips/skipped 计数)、`tripsyImportFailed`(reason)。失败类入 `errorEvents`。

## 测试 Checklist

- [ ] dated 多日行程：天序、跨天航班 dep/arr dayOrder、住宿 nights、当地分钟全对（用新疆 16 行程样本回归）。
- [ ] 天数 = 真实日期跨度（无多出的空尾天）。
- [ ] 未排期点：地理归并到正确锚点天；无坐标兜底最后一天。
- [ ] dateless 行程：压成 1 天、标题"想去的地点"。
- [ ] 大陆时区行程（新疆）不被误判跨时区（`TimeZoneCanonicalizer`）。
- [ ] 重复导入幂等（第二次全部跳过）。
- [ ] 合并不覆盖已有 Carry 行程/打包清单。
- [ ] 图片附件字节写回沙盒、可在条目详情查看。
- [ ] 缺列/损坏库容错不崩。
- [ ] 导入后 `syncItineraryDays()` 不会删天/搬错地点。

## 产品决策（已定）

1. **入口形态**：**分两期**。一期做 **Carry 内文件选择器**（`.fileImporter`，复用现有「导入备份」机制，快且可控）：用户在 Tripsy 导出 → zip 存「文件」App → Carry 设置 →「从 Tripsy 导入」→ 选 zip。二期做 **系统分享面板接收**（注册 zip / Tripsy 导出 UTType，Tripsy 导出时直接分享给 Carry、一步到位），优化体验。**本 spec 实现范围 = 一期（方案 A）。**
2. **逐行程勾选**：预览页**支持**逐个行程勾选/取消，默认全选，可只导部分。
3. **同名去重**：纯按 **UUID 去重**，不按行程名；已存在同名但不同 UUID 的行程**不提示**、正常作为新行程导入。
4. **Onboarding 露出**：**不做**。不把"从 Tripsy 导入"放进新用户 onboarding。

## 关联

- 复用：[[itinerary-attachments]]（附件字节随备份写回）、[[itinerary-timezone]]（大陆时区归一）、[[itinerary-transport-lodging]]、[[dateless-planning-trips]]（dateless 单天约束）、[[itinerary-flight-name-localization]]（机场名后补）。
- 个人迁移记忆见 [[carry-tripsy-import-converter]]（离线 Python 原型，已验证）。
