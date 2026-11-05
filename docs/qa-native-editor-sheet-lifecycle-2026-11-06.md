# 新建行程改名后误报编辑占用
## 问题与根因
用户在新建行程、修改名称后看到“Couldn't save changes / This account is being edited elsewhere”。这条文案来自本机账户编辑组互斥校验，不是服务端证明另一台设备正在修改。
真实 `PackingListView → EditTripView` 链路已复现会话泄漏：合成账户创建新行程后打开改名弹窗，名称保存成功、弹窗也关闭，但 `nativeEditing.hasActiveSessions` 仍为 true。临时追踪显示，页面后来确实生成过带有效 generation 的关闭回调；真正执行的却是首次构建页面时捕获 `generation=nil` 的旧回调，而当前会话 generation 非空，原有安全校验随即跳过释放。遗留会话会拦截后续不同组的编辑和页面自动保存，产生错误提示。
简单单弹窗测试在等待实际关闭后可以通过，不能代表真实多弹窗页面。初次测试仅等 600ms 导致的失败被排除；最终根因依据是实际页面中的旧回调调用记录与关闭后仍持有会话的断言。
## 修复
- `nativeEditorSheet` 增加明确的 `sessionKey`，不在父页面计算 body 时预先创建租约释放回调。
- Bool 与 item 两类 sheet 由各自稳定的 `StateObject` 保存一次呈现的关闭动作，待弹窗内容实际出现后再捕获当前会话 generation；关闭时先取出并清空动作，再释放会话并执行后续刷新。
- 重复 appear 不替换同一次呈现的关闭动作，重复 dismiss 不重复执行；重开可以捕获下一次会话。原有 generation 校验保留，旧弹窗不能关闭替换后的新会话。
- 同步更新 21 个现有租约 sheet 入口，包括行程改名、清单/场景选择、行程详情、备注、费用、住宿、交通、照片导入、背景裁剪及费用明细。没有取得租约的普通 picker/只读展示仍可使用默认参数。
- 保留 owner/group 继承、真实并发编辑阻止、失败时保留草稿、账户撤销和同步投影保护；未清空锁表、放宽互斥或吞掉保存失败，没有改服务端协议或文案。
## 验证
1. 临时诊断使用真实 SwiftUI 行程页与改名页、内存账户和合成 Seoul 行程；仅以临时通知触发与页面按钮相同的打开/保存操作，没有键盘自动化或真实账户数据。旧实现中名称已改但租约未释放的断言失败；同一流程使用修复后通过（5.094 秒）。追踪、通知入口和临时实际页面测试已从最终产品源码移除，诊断源码/结果留在本机证据目录。
2. 新增持久回归 `NativeEditorPresentationLifecycleTests`：实际 SwiftUI 多 sheet 呈现，创建后连续两次改名、关闭后可取得另一组编辑租约、item 取消/重开、生命周期早于租约建立、重复 appear/dismiss、旧关闭动作不能释放新会话。
3. 既有 `NativeEditorLeaseTests`、`NativePersistenceTests`、`NativeSyncBarrierTests` 同跑，检查未保存草稿、真正双窗口互斥、只读嵌套、账户撤销、远端冲突、保存回滚及同步屏障。
最终两轮各 33 项通过、0 失败：`final-round1-r2.xcresult`、`final-round2.xcresult`。iOS Release arm64 未签名构建成功，编译 warning=0；语言审计 0 错误/0 警告，`git diff --check` 通过。首轮新测试曾漏标注 Fixture 的 MainActor，补正后重跑；该次编译失败不计通过。不将测试宿主的系统服务日志写作零运行告警。
## Review
- 检查了 Bool/item 包装器与 21 个 key 的对应关系；所有旧的页面级 `dismissal` 调用均已迁移，保留底层 generation 方法供实际呈现时捕获。
- 后续刷新在正确 generation 被释放后执行；关闭动作先置空，避免重入/重复回调再执行。
- 未使用 onDisappear 提前释放，避免子弹窗覆盖、页面切换过程中把尚未保存的草稿误判为关闭。
- 临时日志/通知不在最终源码；没有修改 `EditTripView` 的名称保存、600ms 成功停留或业务持久化实现。
## 证据与边界
本机产物：`/tmp/carry-editor-busy-20261106`。旧失败证据为 `actual-packing-baseline.xcresult` 和 `confirmed-stale-dismissal.log`；修复对照为 `actual-packing-fixed.xcresult`。
本机 Xcode 与已安装 CoreSimulator 版本不一致（1174.21.0 / 1174.9.2），iOS Simulator 运行无法启动，没有将其计为通过。实际原生生命周期及账户回归在 Mac Catalyst 测试宿主运行；iOS 使用独立设备 Release 编译检查。没有为此修改/安装系统开发组件。
本轮按用户要求提交并 push，未覆盖安装手机；iOS 实体机的新建→改名→返回→再次编辑仍需更新安装后的用户验收，不以 Catalyst 测试替代。
