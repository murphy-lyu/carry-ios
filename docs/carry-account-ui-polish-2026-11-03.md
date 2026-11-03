# 账户 UI 整理验收记录
## 范围与原因
已查看用户的9张实体截图。问题来自页面层级和容器：重复大标题、危险操作组内展开验证、长说明挤占选择区、主要按钮位于长列表末端，以及confirmationDialog与设置现有alert不一致。
本次只修改AccountView、账户AI连接页面、迁移页面及18项九语言文案；身份验证、删除服务端、迁移提交、权限与数据范围保持现有实现。未为暂停删除新增恢复入口或误导性成功状态。
## 调整
- 登录页只保留导航标题，减少首屏重复信息；保留官方Apple按钮及至少44pt法律链接，长文案在可访问性字号下可自动纵排。
- 账户资料收紧，迁移与AI入口合组；服务器持久化状态明确写作“已保存到账户”，不暗示所有设备已收到。
- 删除再验证为独立sheet，提供取消并阻止忙碌状态滑动关闭；删除中为紧凑Form，保留原10秒收据轮询。提示只说明删除可能耗时，不保证后台一直运行。
- 退出、删除、迁移使用原生alert与显式取消，跟Settings的既有做法一致。不可逆、独立本地/iCloud保留及离线缓存说明仍在。
- 迁移先选行程，备份和文件限制可展开，底部常驻主操作及所选数量。两行名称限高，辅助功能保留完整名称；去掉相同的目的地副标题。
- AI页面保留权限边界、同一身份和地址，去掉原生Form行标签的额外最小高度。
## 自行 Review
- 修正初稿“已同步”为“已保存到账户”，保持状态语义准确。
- 删除说明补回“独立的”本地与iCloud数据限定，避免把账户缓存说成独立副本。
- 父任务Review指出删除暂停状态不可承诺后台持续运行；九语已改为中性耗时提示。
- 保留登录/删除nonce、状态核验、迁移选择及调用，未改服务和模型。
## 截图证据
使用真实SwiftUI页面的原生UIHosting/XCTest窗口，配合独立临时数据库与合成身份；没有使用真实账户或行程，也没有发起Apple授权。
独立iPhone17Pro / iOS27模拟器，浅深色：登录、概览、AI、迁移、删除中、再验证sheet、退出与删除alert、可访问性大字号；另核对中文和德文长文案。共30张主截图、4张登录可访问性截图，另补4张最终删除提示截图。
主截图：`/tmp/carry-account-ui-polish-evidence-20261103/localized`。中文大字号：`/tmp/carry-account-ui-polish-evidence-20261103/zh-large-signin-dark.png`。
中文环境仅覆盖SwiftUI locale，系统Apple按钮沿用模拟器英文，不能据此声称Apple系统授权已完成中文验证。
## 验证边界
临时UI状态初始化、截图测试文件、虚假配置均在最终构建前移除。截图为页面布局证明，不替代完整设置导航、真实Apple授权或真机验收。本任务未安装iPhone、发布、上传真实行程或操作删除。
模拟器宿主日志出现地图资源缺失、AttributeGraph/Metal及系统辅助服务信息，不能写成零运行日志告警。
## 自动验证记录
- 正确回归流程使用`carry-native-qa/run.py`、Node24与受监督8891–8893合成服务，正常模拟器签名。两轮各384项：383通过、1项既有手工场景跳过、0失败。
- 初次直接xcodebuild遗漏模拟器签名与本地HTTP夹具，分别出现Keychain/持久层及连接拒绝错误；这些日志保留且不计通过。未为通过测试修改产品行为。
- i18n审计：0错误、0警告；git diff --check通过。
- 原生两轮结果：`/tmp/CarryAccountUI-supervised-final-20261103/round-1.xcresult`、`round-2.xcresult`。正常签名、合成HTTP完整运行，两轮编译warning均为0。
- 删除中最终提示截图覆盖旧版：`/tmp/carry-account-ui-polish-evidence-20261103/deletion-final/deleting-final-zh-Hans-dark.png`、同目录`deleting-final-en-dark.png`及对应浅色。主截图目录的旧deleting图不代表最终文案。
- 父任务实际检查登录、再验证、删除中及两个alert，确认布局和原生确认方式；最后提示事实已按Review修正并重拍。
- 最终Release通用iOS模拟器构建成功（arm64/x86_64），编译warning 0：`/tmp/carry-account-ui-release-final-20261103.log`。构建不等于签名真机安装或App Store验收。
