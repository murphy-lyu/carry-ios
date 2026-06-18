# 照片回溯行程 · 发布前合规清单

> 配套 spec: `specs/photo-trip-reconstruction.md`。
> **核心事实（决定后面所有判断）**：本功能**不请求任何相册权限、不访问相册库（不碰 `PHAsset`）**。
> 用户用系统 PHPicker 主动挑了哪几张，App 才拿到那几张的图片数据，**仅在端上**从中读 EXIF
> （时间+地点）+ 生成缩略图。**不上传、不外传、不做任何网络传输**；原图永不拷贝；只把一张小缩略图存进本地行程库。

## 1. 相册权限 ✅ 已做到「零授权」

- **没有 `NSPhotoLibraryUsageDescription`**（已从 Info.plist + InfoPlist.xcstrings 移除）——因为我们根本不访问相册库。
- `.photosPicker` 不传 `photoLibrary`，是纯进程外选择器，**连「允许访问所有照片」弹窗的可能性都没有**。
- 这是隐私敏感用户的最大顾虑点，直接从源头消除。

## 2. App Store Connect · App 隐私（“nutrition label”）

判断依据：Apple 对「收集（collect）」= 数据**离开设备**。我们**不传**。

- **Photos / 照片**：声明 **「未收集数据 / Data Not Collected」**——照片+派生的位置/时间从不离开设备，只本地存缩略图。
- **Location / 位置**：同理不计入收集（端上聚类用，不上传、不关联身份、不追踪）。
- ⚠️ 前提：**一旦将来做云同步/上传含照片的行程，此结论立刻失效**，必须回来改。

## 3. 隐私清单 `PrivacyInfo.xcprivacy`

- `NSPrivacyCollectedDataTypes` 维持**空**（不收集）。
- `NSPrivacyAccessedAPITypes`：本功能未使用 Required-Reason API（EXIF/`CGImageSource` 不属于文件时间戳等类别）→ **无需新增**。

## 4. 隐私政策（独立仓库 `carry-legal`，**不在本仓库**）

- ⬜ **待办**：加一段「照片」声明（口径与上面一致）：
  > 当你主动选择照片时，Carry 仅在你的设备本地读取这些照片的拍摄时间与地理位置，用于自动生成行程。
  > Carry **不访问你的相册库、不请求相册权限、不上传也不存储你的原始照片**，仅在你的设备上为行程保存一张缩略图。
- 9 语言同步；大陆版（PIPL 第 14 条所在文件）也补此段。

## 5. 权限交互与边界（已实现）

- 点「用照片还原行程」→ 直接拉起系统照片选择器，**无任何前置授权弹窗**。
- 没有「拒绝授权」分支（因为根本不索权）；选了没有可用照片 → 友好空态。
- 选了带 GPS 的照片即正常生成；无 GPS/越界 → 诚实分到两个区块说明原因。

## 6. 技术实现要点（已落地，备查）

- 读取：`PhotosPickerItem.loadTransferable(type: Data.self)` 拿所选图字节 → `CGImageSource` 读 EXIF GPS（WGS-84）+ DateTimeOriginal + 降采样缩略图。串行处理、逐张即时释放，内存有界。
- 坐标：EXIF GPS 与系统相册同源 → 不再有「相册有位置、Carry 说没有」的问题；境内过 `CoordinateTransform` 转 GCJ-02。
- 时间：EXIF 本地墙钟按设备时区解释（与行程日期口径一致）。
- 代价/取舍：① 逐张载入原图数据比 `PHImageManager` 略重，已用单次 40 张上限 + 进度态兜住；② 不存 `assetLocalIdentifier`（不绑库），故「点缩略图回相册看原图」本版不提供——符合零授权取舍。

## 7. 提交前自检清单

- ⬜ 真机走一遍：点入口直接出选择器、无权限弹窗。
- ⬜ App Store Connect 隐私问卷按第 2 条填「未收集」。
- ⬜ 隐私政策补「照片」段并上线（raw CDN 有缓存，按 CLAUDE.md 用 GitHub API 确认）。
- ⬜ 确认带 GPS 真照片的 EXIF 读取/聚类/两个分桶符合预期（模拟器无法验，需真机）。
- ⬜ 大批量（接近 40 张、含 iCloud 未下载原图）导入的耗时/内存观感可接受。
