# Tripsy 与 Carry 的 AI 接入比较

核对日期：2026-10-25。范围为 MCP 接入方式、能力和用户体验，不评价完整旅行 App。依据用户两张手机截图、Connections 截图、厂商公开文档/开源 README，以及本会话实际可用的 Tripsy 工具目录。仅调用无用户内容的状态和操作指引工具，没有读取私人行程或修改 Tripsy 数据。

## 判断

两者均采用 MCP 与 OAuth。Tripsy 已有账户 API，MCP 将操作转给账户服务；Carry 当前由远程队列把命令交给手机的 SwiftData 业务层执行。对“手机收起来后继续用 Codex 改行程”的目标，Tripsy 的服务端执行方向更合适。Carry 当前方案适合保留现有本地/iCloud 数据模型的第一版，但要明确打开 App 执行的限制，不能把它描述成等同的即时服务。

这不撤销已确认的 Carry 方案，也不作为改建服务端主数据库的批准。手机关闭时 Tripsy 的实际写入及多设备读回尚未做实测；后台独立执行的判断来自公开 API 和 MCP 下游调用结构，不是本次验收结果。

## 对照

| 维度 | Tripsy：已核对信息 | Carry：当前实现 |
|---|---|---|
| 接入 | 手机页面给出服务器地址和三步操作；托管 MCP + Tripsy OAuth | MCP + OAuth/PKCE；手机输入一次性配对码，逐行程授权，物品库独立授权 |
| 执行 | 公共 REST API 提供行程及子资源读写；MCP 按当前用户身份调用 API | 手机前台、联网且本地数据库加载完成后执行；离线请求排队 |
| 查询新鲜度 | 读取账户 API；实际客户端同步延迟未测 | 服务端读取授权快照，返回捕获时间；不是实时设备状态 |
| 覆盖 | 当前连接暴露 54 项工具，涉及行程、活动、住宿、交通、费用、文档、预订邮件和同行者等 | 40 项工具，覆盖行程、地点、交通、住宿、打包、物品库、搜索及路线；不开放附件、健康数据、系统日历叠加和整库操作 |
| AI 操作约束 | 专用 itinerary guidance：每个地点单独建项，住宿/交通分开，时间使用 UTC + 当地 IANA 时区，位置使用真实坐标，封面用有效 URL | typed schema、业务校验、明确能力边界；版本校验、请求去重、设备保存回执 |
| 防覆盖/失败反馈 | 公开指引没有建立与 Carry 相同的版本/回执保证；未测试，不据此断言其没有保护 | `expectedRevision`、重复请求相同 ID、`queued/executing/applied`、取消/冲突/撤销均有实现和本地测试 |
| 打包 | 本次 MCP 目录没有专用打包清单工具；不能据此判断整个 Tripsy 产品没有此功能 | 使用 Carry 现有打包模型、推荐与明确打包状态操作 |

工具数量只说明暴露面的大小；真实数据正确性、失败恢复和连接操作成本更有比较价值。54 是本会话目录数量，厂商页面标注的 55 包含可选自托管 raw API，不能当作版本故障。

## Connections 截图说明

截图确认 Tripsy 插件已经安装，并通过 OAuth 连接了账户。本会话也确实取得 Tripsy 工具，状态检查返回认证和 API 可用。

Connections 中的目录入口涉及插件分发、账户授权与产品展示。仅部署一个 MCP URL 不会自动获得相同的目录入口。自定义 MCP 接入和目录分发需要分别处理；Carry 当前先验证自定义连接，不承诺已上架插件目录。OpenAI 官方术语将插件定义为可分发的技能、连接器及工具集合。

## 值得借鉴的部分

1. 在 Carry 中给出服务器地址、连接步骤和可直接复制的对话例子。目前“先从 Codex 发起授权”的提示，对首次使用者信息不足。
2. 将创建高质量行程的规则集中提供给 AI：当地日期/时区、航班两端时区、酒店独立建项、真实坐标、未知信息留空。不要让工具多就等于 AI 知道怎么用。
3. 让待执行、已保存、快照时间和连接故障容易理解。尤其不能把排队成功显示成行程已经写入。

这些属于后续改进建议，本次研究没有据此新增界面或替换架构。如果长期目标要求手机完全关闭时也立即改动，需要重新评估账户体系、旅行数据主存储、多设备冲突、运维和隐私政策，不宜在当前验收中临时拼接。

## 来源

- [Tripsy 托管 MCP 接入说明](https://tripsy.app/mcp)：地址、OAuth 和支持能力。
- [Tripsy 公共 API](https://docs.api.tripsy.app/)及 [OAuth 说明](https://docs.api.tripsy.app/oauth2)：账户/旅行资源接口与鉴权。
- [Tripsy 官方 CLI/MCP README](https://github.com/tripsyapp/cli/blob/main/README.md)：MCP 下游账户 API 调用、客户端配置、工具与操作指引。
- [Tripsy ChatGPT 集成页](https://tripsy.app/integrations/chatgpt)：官方插件安装入口与示例。
- [OpenAI 官方术语表](https://learn.chatgpt.com/docs/glossary)：插件与连接器的定义。
- Carry 对照：`specs/codex-mcp-integration.md`、`scripts/carry-mcp/README.md`、`worker.js`、`CarryAutomationConnection.swift`。当前线上/设备验收边界见 `docs/codex-integration-qa.md`。
