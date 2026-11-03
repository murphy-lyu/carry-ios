# Carry 真机安装记录
日期：2026-10-28。用户在组件检查完成后进一步明确“继续吧，可以安装到 iPhone”，授权先安装当前开发版本。此次安装不代表账户/云同步/AI 完整功能验收完成。

## 安装与保护
- 安装来源：`codex/carry-integration` 的 `355e16b`，已通过两轮原生 107/107、服务端 57/57 组件验证及 Release/strict codesign/九语言检查。
- 目标：已连接的实体 iPhone 17 Pro；使用原 Bundle ID `app.nevestudio.carry`，原 Carry 原位更新，没有创建额外 App，也没有卸载/清空数据。
- 构建：Release，版本 `1.0 (3)`，Team `25RAM7275Z`，CloudKit `Production`；签名描述文件包含该设备且有效。账户发布开关仍为 false，未部署新服务或上传 TestFlight。
- 安装前确认 Carry 主进程未运行；完整复制 AppData 与 App Group 至本机受限备份目录，46 个文件，逐文件 SHA256 清单。原始目录、日志及结果只保存在 `~/Library/Application Support/Carry Development Backups/`，不上传 Git。
- 备份 SQLite `quick_check` 通过，核对 13 个行程、52 个行程天、42 个地点、566 个清单物品。

## 实际结果
- CoreDevice 返回安装成功，随后原 Bundle ID 启动成功，查询到主进程与 Widget 扩展来自新安装的 App 路径。
- 安装并启动后重新复制 App Group 检查，SQLite 完整性通过；上述四类记录数量均未变化，行程 UUID 集合摘要与安装前一致。没有用“安装成功”替代数据保留检查。
- iPhone Mirroring 显示 “iPhone in Use / Lock your iPhone to connect”，未继续镜像操作，没有要求用户中断手机使用。此次没有视觉、帧率、Apple 登录、双设备或完整同步验收结论。
- 当前构建用于继续真机调试；服务端上传会话、真实资产迁移、全业务写入口、完整账户删除/恢复及范围化 AI 执行仍按既有 spec 继续，不因装机而开启未完成入口。
