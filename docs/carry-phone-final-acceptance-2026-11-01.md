# iPhone 最终界面验收
日期：2026-11-01。源码基线701e353；实体机iPhone 17 Pro，使用原Carry，账户与AI只在专用验收包开启。
- 用户锁屏确认后重连；原先镜像返回iPhone in Use，后截图已连接但坐标点击报noWindowsAvailable。执行镜像窗口暴露的Raise动作并返回Home后恢复点击；此为工具窗口控制问题，未更改Carry代码。
- 手机首页实际显示Single Day verified单日与Remote Conflict已选择远端名称，确认此前Mac变更到实体iPhone可见。原本地行程仍在列表，未迁移上传。
- 手机Settings→Connect AI实际显示管理连接、同Apple ID提示、正确MCP地址与复制按钮。
- 其余项目进行中，不预记通过。

## 后续实测与修复
- 手机地点详情展开后费用¥42、原合成备注和附件名称均正确；Quick Look实际显示Carry synthetic attachment acceptance fixture. No personal travel data.正文。
- 发现Quick Look标题显示UUID；改为每租约独占私有UUID目录内使用有界、安全原文件名，保持blob身份不变。修复准备失败时目录回收；取消、关闭及同名隔离回归覆盖。两轮最终原生每轮384总项/383通过/1手工跳过/0失败/0运行时警告。iOS Release v3、Mac/iPhone Debug通过，九语言0/0。
- Release v2与尚未结束的v1意外共用DD被build.db锁拒绝；等待v1退出后v3重新构建成功，不记v2通过。
- 尝试OS进程网络阻断而不改机器网络，curl确被拒绝；直接启动Catalyst却在RunningBoard初始化阶段无法建立GUI，已停止该测试进程并按正常方式重开。该试验不能作为产品离线验收通过或应用故障证据。
- iPhone Time Profiler尝试返回Waiting for device to boot / timeout，未取得trace，不声称性能测量通过。

## 托管真实删除与恢复
- 首轮：预览1c0296c0-7cda-499b-967e-069373cc2b82，经第一方Allow后以request afcf6b46-86d8-4e0e-b219-0f0286eeb8ac原子删除合成trip25fb0d37及原day。Mac编辑draft仍在，出现Unsynced changes to a deleted item；Review deletion列明影响范围，恢复后服务器root v4/day v3，原ID保留、名称为本地draft。
- 发现恢复后未自动requestSynchronization，需手动Sync now。已在既有成功resolve分支调用controller retry回调，失败分支不调用。
- 修复复测：预览ed47bdf6-17fc-4aae-836f-a9d568cbb016，request5403f9ec-bc12-4978-8760-7d18ca74831e再次仅删除同一合成trip/day。Mac选择Restore and keep my draft后未点Sync now，MCP直接读回root v6/day v5、deletedAt均nil、名称Carry QA Auto Recovery verified 20261101；账户界面Changes saved to your account。
- 最终源码 `/tmp/CarryRecoveryFinalQA-20261101` 两轮均384总项/383通过/1手工跳过/0失败/0运行时警告。三平台构建均成功且0编译警告；同bundleId最终手机包已安装启动。

## 预览诊断与当前边界
- Mac一次窗口状态读回只得到主窗口，未稳定看到Quick Look，故追加3条不含文件名/ID的临时阶段日志定位。复测实际出现Quick Look独立窗口，AX含正文和Carry-QA-attachment-20261101.txt，日志仅prepared→binding_active，未出现owner_disappear_active。证据不支持新增生命周期缺陷；未移除既有onDisappear清理，临时日志已全部撤下并重新构建Mac成功。
- 用户再次熄屏后，手机主列表真实显示Carry QA Auto Recovery verified 20261101，日期仍1天，证明恢复结果已到实体机。
- 手机最终标题复核阶段工具再次noWindowsAvailable，尽管截图正常；已请用户将镜像窗口保持在当前桌面前台，不据此修改业务代码。
- 真正物理断网重开、iPhone12硬件性能trace、第二台iOS专项仍保留；第二台iOS此前用户明确延期。此处不把进程级断网试验或iPhone17表现当作这些验收通过。

## 用户带走手机后的电脑收尾
- 用户要求停止占用手机，已退出iPhone镜像；其后只做电脑/模拟器检查和构建，未再安装或启动手机。
- 追加隔离回归：给临时预览赋予可写权限并用FileHandle原地修改；旧硬链接实现导致原cache及另一个租约都由17字节变19字节，真实4条内容断言失败（before-fix-v2结果）。首次直接Data.write因原0400属性被拒绝，不能把该拒绝当作隔离通过。
- 改用独立copyItem，彻底分离预览与不可变cache；回归验证原始内容、另一同名租约和删除清理均保持正确。最终 `/tmp/CarryPreviewIsolationFinalQA-20261101` 两轮各384总项/383通过/1手工跳过/0失败/0运行时警告；上述隔离用例两轮均实际通过。
- 最终Release、Mac Debug、iPhone Debug构建均0编译警告成功，九语言0/0、diff检查通过；只读Review未发现新增actionable问题。最终Mac已签名重开，最终iPhone包已签名准备好，未在用户带走手机后覆盖安装。
- 手机当前安装包已包含原名预览及恢复后自动同步；最后新增的独立副本隔离补丁待下次连接安装。最终手机Quick Look标题复核、物理断网重开、iPhone12硬件trace及第二台iOS仍按证据边界保留，不冒称电脑/模拟器代替真机。

## 2026-11-03：手机重新连接补验
- 基线5fff33f，实体机仍为iPhone 17 Pro。安装前复制当前Carry容器至本机受限备份，55文件、34,956,942 bytes，6个SQLite integrity_check全部ok，目录0700/文件0600；此为容器复制，不宣称停机原子快照，不含Keychain导出。
- 验证最终包strict/deep签名后，以原bundle ID覆盖安装成功并启动。最终独立副本隔离修复已到手机，此安装待办完成。日志：`/tmp/carry-preview-final-install-20261103.log`、`/tmp/carry-preview-final-launch-20261103.log`。
- 镜像真实显示账户头像、16条行程及既有合成同步/冲突/恢复行程；原本地行程仍在。未新增私人行程迁移或AI授权。
- 当前Codex连接实际list_trips成功，无需重新授权；只返回原授权的两条合成行程，恢复行程仍root v6、subtree v50且无删除标记。此证据说明该连接跨两天后可用，不代表旧CLI失效根因或多进程长期兼容已经解决。
- 镜像截图和键盘输入可用，但坐标点击两次返回noWindowsAvailable；窗口Raise后键盘可开Carry，点击仍失败。已请用户将镜像窗口切至当前桌面前台，最终预览标题和物理离线场景暂未记通过。
- Time Profiler按设备+实际PID附加返回Cannot find process；devicectl再次确认同PID仍运行，按进程名尝试后返回Waiting for device to boot及exit13。未获得有效trace，不能据此推断产品卡顿或性能通过；不使用iPhone17结果替代iPhone12硬件验收。
