# 吸顶修复集成与手机安装
用户明确授权将吸顶修复集成当前开发版并安装到本人手机，由用户验证透叠。
## 集成来源
- 以当前手机最近安装的账户恢复开发基线 `8db62e0` 为起点，包含 `codex/carry-integration` 的后续开发与账户恢复代码。
- 独立集成分支 `codex/header-device-integration` / 工作树 `Carry-header-device`，无冲突 cherry-pick `6824a17` 得到 `6c407c4`。相对基线只有两处日期头实现及两份文档变更。
- 不改变其他会话工作树、main 或远端分支；后续开发应继承本集成提交，避免再次安装不含修复的旧基线。
## 构建与安装
- 手机：本人 iPhone 17 Pro，iOS 27.2 / 24B119。原 Bundle ID `app.nevestudio.carry`，版本仍为 `1.0 (3)`。
- Debug 实体设备签名构建成功，编译 warning 0；独立 DerivedData `/tmp/CarryHeaderDevice20261104`。
- 安装产物复用上一份已装机开发包的 Secrets 配置，其他配置逐项比较一致，保留开发账户及 AI 门禁；仅改打包产物，不把门禁或密钥提交源码。
- entitlement 字典与上一份装机包完全一致，Team `25RAM7275Z`，CloudKit `Development`，描述文件包含目标手机；strict/deep 签名验证通过。
- CoreDevice 原位更新安装成功，没有卸载应用、清空容器、退出账号或操作私人行程。随后按原 Bundle ID 启动成功。
## 数据保护
- 安装前停止原 Carry 及其 Widget 进程，复制 AppData 与 App Group 到本机受限目录；59 文件、40,758,885 字节，保存 SHA-256 清单。
- 安装后、启动前再次复制容器：7 个 SQLite 主文件及 7 个 WAL 与安装前逐字节相同，7 个 integrity_check 全部为 ok。不是仅凭安装成功判断数据保留。
- 备份位于 `~/Library/Application Support/Carry Development Backups/20261104-before-header-integration`；安装后副本为同目录下 `20261104-after-header-install`。不上传备份或导出 Keychain。
- 构建、签名、安装、启动日志位于 `/tmp/carry-header-qa/integrated-device-*`。
## 验收状态
安装与启动完成；原始吸顶透叠效果由用户在手机上验证。没有自动点击或滚动手机，也未将成功安装写成视觉验收通过。
