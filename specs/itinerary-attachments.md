# 行程附件：文件 / 照片 / 链接

> **Status: Shipped（2026-06-19）。** 范围 = 全行程实体（交通 + 住宿 + 地点）；类型 = 文件 + 照片 + 链接。
> **后续补齐（2026-06-19 续 3）——原 v1 两点取舍均已实现**：
> 1. **拍照已加**：添加菜单含「拍照 / 选照片 / 选文件 / 添加链接」。拍照走 `CameraPicker`（UIImagePickerController `.camera` 包装）；仅在 `isSourceTypeAvailable(.camera)` 为真时显示该项（模拟器自动隐藏）。Info.plist + InfoPlist.xcstrings 已加 `NSCameraUsageDescription`（9 语言）；拍得的照片即普通照片附件、隐私政策附件条已覆盖。
> 2. **新建实体也能加附件**：owner 为 nil（新建）时附件**缓冲**在 `pending: [PendingAttachment]`（文件已落沙盒），保存创建实体拿到 id 后 flush 入库；取消则文件成孤儿、由 `reconcileAttachmentFiles` 兜底回收。`AttachmentEditSection`/`.attachmentAddFlow` 按 owner 是否为 nil 分流（入库 or 缓冲）。地点恒为既有实体（新地点经 AddStopView 添加），用 `.constant([])`。
>
> **费用/备注/附件在编辑页与详情页均各自独立卡、固定顺序（费用 → 备注 → 附件）。**
> 实现用 SwiftUI 原生 `photosPicker` / `fileImporter` / `quickLookPreview`（图片/PDF 预览），无 UIKit 包装。
> **分享过滤已审计通过**：全仓 `.attachments` 仅出现在数据层（model/store/backup）+ 6 个详情/编辑视图；`TripSharePoster`、行程文档导出、分享清单等对外渲染器**均不读附件** → 天然不外泄。

## 动机
出行时常有需要随身留存的材料：租车合同 / 取车单、机票行程单、酒店确认函、景点门票、网盘链接等。现状无处可放。Tripsy 的「添加文件、照片或链接」即此能力。

核心诉求两条：
1. 给行程实体挂**文件 / 照片 / 链接**，详情里可查看、预览、打开。
2. **分享行程给他人时必须过滤掉附件**——合同含身份证号、付款信息等隐私，绝不能随分享/导出泄露。

## 范围
通用附件，挂在三类实体上：`ItineraryStop`（地点）、`TransportSegment`（交通）、`LodgingStay`（住宿）。一套模型、一套 UI、一套规则，避免日后逐类型重做。

## 数据模型

新增 `@Model final class ItineraryAttachment`（轻量迁移：新建 model = 新表，单一 SchemaV1 自动处理；项目未发布、无线上数据）。

```
@Model final class ItineraryAttachment {
    var id: UUID = UUID()
    var kindRaw: String = AttachmentKind.file.rawValue   // file / photo / link
    var displayName: String = ""        // 文件名 / 用户起的名 / 链接标题（空则回退）
    var fileName: String = ""           // 沙盒内文件名（file/photo 用；link 为空）
    var utiOrExt: String = ""           // UTType 标识或扩展名（图标/预览用；link 为空）
    var urlString: String = ""          // 链接（link 用；file/photo 为空）
    var sortOrder: Int = 0
    var addedAt: Date = Date()
    // 归属：三选一（仅一个非空），镜像 StopPhoto ↔ ItineraryStop 的关系范式
    var stop: ItineraryStop?
    var segment: TransportSegment?
    var stay: LodgingStay?
}

enum AttachmentKind: String, Codable { case file, photo, link }
```

- 三个可选反向关系仅一个被设置（按挂载实体）。父实体加 `@Relationship(deleteRule: .cascade) var attachments: [ItineraryAttachment]?`，删实体级联删附件（并清沙盒文件，见下）。
- 加入 `SchemaV1.models`。

## 存储（关键：二进制不进 SwiftData）
- **文件 / 照片**：字节写**沙盒**（`Application Support/Attachments/<uuid>.<ext>`），model 只存 `fileName`。沿用背景图 / `StopPhoto` 既有「字节在沙盒、文件名进 model」范式，**禁止把大文件塞进 SwiftData**（撑库、拖慢）。
- **照片**：可复用 `StopPhoto` 的缩略图思路（存约 640px 预览 + 原图？或仅原图）；首版可只存原图 + 列表用系统缩略。
- **链接**：纯 `urlString`，无沙盒文件。
- **删除**：删附件 / 删父实体（cascade）时，必须**同步删沙盒文件**（就地删 + 兜底回收扫描），否则孤儿文件堆积。集中在 `TripStore.removeAttachment` 单一漏斗。

## UI

### 录入（编辑页）
各实体编辑页（`StopEditView`/`TransportEditView`/`LodgingEditView`）加一行「添加文件、照片或链接」→ 弹 `confirmationDialog`：
- 拍照（相机）
- 从相册选（PHPicker）
- 选文件（UIDocumentPicker，UTType: pdf / image / 通用 data）
- 添加链接（文本输入 + 可选标题）

已添加的附件在该页以可删列表呈现（左滑删 / 编辑态减号）。

### 查看（详情页）
各详情页（`StopDetailView`/`TransportDetailView`/`LodgingDetailView`）加「附件」分组卡（有才显），每行 = 类型图标 + 名称（+ 大小/类型副标）。点击：
- 文件 → **QuickLook**（`QLPreviewController`）预览
- 照片 → 复用现有图片放大查看
- 链接 → 安全打开（外部浏览器；遵守链接安全约定）

图标按 kind/UTI：PDF `doc.richtext`、图片 `photo`、链接 `link`、通用 `doc`。

## 分享 / 导出过滤（硬约束，设计第一天钉死）
**附件 private by default，绝不进任何对外路径**：
- `TripSharePoster`（分享海报）—— 不含附件（本就是视觉海报，确认不带）。
- 行程 PDF / 文档导出（`ItineraryDocument*`）—— 显式排除附件。
- 分享打包清单 —— 不含。
- 自检：凡是「把行程数据交给 app 之外」的路径，一律不带 `attachments`。新增任何导出/分享路径时，默认排除附件，需显式审查。

## 备份 / 还原（≠ 分享）
- 备份是用户自留、需完整：附件**随备份带上字节**（base64 进导出包，像背景图那样），还原时写回沙盒。`DataBackupManager` 新增 `BackupAttachment`（可选字段、nil 兼容旧备份），读写两侧 + 大小注意（多个大 PDF 会让备份包变大，评估是否给单文件大小上限）。
- **复制行程** `duplicateTrip`：深拷贝附件记录 + **复制沙盒文件**（新 uuid 文件名），归副本。

## 隐私
- **纯本地存储、不上传任何服务器**。隐私影响有限。
- 仍按约定在 `carry-legal`（`privacy/zh.html` + `index.html`，中英同步、PIPL 第 14 条不删）补一句：用户添加的文件/照片/链接仅存于本机设备、不上传、不随分享外泄。

## 埋点
`CarryLogger.Event` 加 `attachmentAdded`（context: kind）、`attachmentOpened`；同次改动接线（禁止只定义不调用）。

## 全链路改动清单（实现时逐项核对）
1. Model：`ItineraryAttachment` + `AttachmentKind` + 三父实体加 `attachments` 关系；加入 `SchemaV1.models`。
2. 沙盒文件管理器（写/读/删/兜底回收）。
3. `TripStore`：`addAttachment(file/photo/link)` / `removeAttachment` / 排序；删实体时级联清文件。
4. 录入 UI：三编辑页加入口 + confirmationDialog + PHPicker/UIDocumentPicker/链接输入 + 已加列表。
5. 查看 UI：三详情页加附件分组卡 + QuickLook/图片查看/开链接。
6. **分享/导出过滤**：审 `TripSharePoster`、PDF 导出、分享清单，确保不带附件。
7. 备份：`BackupAttachment` 读写带字节；`duplicateTrip` 拷贝文件。
8. 隐私政策更新（carry-legal）。
9. 埋点 + 本地化（9 语言：入口文案、各类型标签、空态、确认删除等）。

## 建议实现顺序（一个 PR 内可分阶段提交，便于回看）
1. Model + 沙盒管理 + Store 漏斗（无 UI，先打地基 + 备份/复制/删除闭环）。
2. 录入 UI（三编辑页）。
3. 查看 UI（三详情页 + QuickLook）。
4. 分享/导出过滤审计 + 隐私政策 + 埋点 + 本地化收口。

## 已定决策（2026-06-19）
- **单文件大小上限 = 25MB**：超限时提示「文件过大」，不入库（防备份包膨胀）。
- **照片存两份**：原图 + 约 640px 缩略图（与 `StopPhoto` 一致）——列表/详情用缩略图、点击看原图。
- **链接不抓标题**（不联网）：用户可手填标题，留空则显示 URL 本身。
