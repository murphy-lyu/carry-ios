# App Store 截图脚本

供制作 App Store 物料截图时对照执行。整理于 2026-06-02。

配套文档：[`app-store-metadata.md`](app-store-metadata.md)、[`release-checklist.md`](release-checklist.md)、[`app-store-submission-guide.md`](app-store-submission-guide.md)。

---

## 总策略

- **真实界面只有 4 个**：地球 / 首页(My Trips) / Smart picks 场景选择 / 物品清单(含天气·插座·汇率信息卡)。6 帧靠「换数据 + 换取景 + slogan」讲故事，不注水。
- **目标人群**：旅行的人（非出差），向女性用户倾斜。倾斜信号藏在数据与功能里（经期 chip、护肤分装、Honeymoon 等），**画面气质保持通用高级，不做粉色少女风**。
- **主题统一深色**：地球在纯黑星空下质感最高，OLED 黑 + 国旗彩色在一排白底截图里最跳。浅色仅用于第 6 帧对比。
- **两组连贯叙事**：第 1→2 帧（地球展开成首页，App 真实交互）、第 3→4 帧（选场景 → 生成清单）。
- **数量**：6 帧为完整版（原 7 帧已将「天气卡」「插座卡特写」合并为第 4 帧）；第 6 帧（深浅对比）为 nice-to-have，可砍成 5 帧。ASC 上限 10 帧。
- 80% 用户只看前 2–3 帧 → 第 1、2、3 帧决定下载率，优先打磨。

---

## 语言策略（出图前先定）

App Store 截图**按本地化语言分别上传**：某语言用户只看到该语言的截图，未上传则 fallback 到主语言（en）那套。所以这不是「要不要翻译」，而是「各市场用户该看到哪套」。

**本质是两套不同的图，不是翻译**：App UI 跟系统语言自动变，所以中文版 = 把模拟机切成简体中文重截 UI + 换中文 slogan，不是重做设计。

| | 英文版（en-US 等） | 中文版（zh-Hans） |
|---|---|---|
| App 界面语言 | English | 简体中文 |
| slogan | 英文文案（见 7 帧脚本） | 中文文案（见 7 帧脚本） |
| 模拟数据 | Santorini / Kyoto… | 目的地可保留英文，行程名建议中文（「圣托里尼蜜月」） |

### 分阶段（独立开发者现实）

1. **首版必做两套**：`en-US` + `zh-Hans`。两个最大的盘子，缺一不可。中国区一屏英文 slogan 转化明显掉。
2. **`zh-Hant`（繁体，港澳台）**：首版可 fallback 到 en/简中；App 已认真做繁体，有余力建议补，signal 好。
3. **其余语言（ja/de/fr/ko/es/pt-BR）**：首版**全部 fallback 到 en-US**，别做。9 套截图维护是灾难，这些区短期也无量。等某区有自然量再针对性补。

> 一句话：**en + 简中是刚需，繁中锦上添花，其余先吃 fallback。**

**省力技巧**：中英两套构图/机型/背景/摆位完全一致，只差「界面语言 + slogan 文字」。把 slogan 做成可替换文字图层、底图复用——出完英文版，切系统语言重截 6 张 UI、替换文字，中文版半小时出。

---

## 必备尺寸

- iPhone 6.9"（必备）
- iPhone 6.5"（必备）
- 同一台设备的同一套界面，**不要混用不同机型**。
- Mac Catalyst 另出一套 Mac 截图（如上架 Mac）。

---

## 全局数据清洗清单（截图前必做）

- [ ] 删除名为 **`Test / New York`** 的行程（上架大忌）。
- [ ] 状态栏统一：满信号、满电、时间锁 **9:41**（Apple 内部约定，别用 12:31/13:10）。
- [ ] 行程标题与日期/物品量必须自洽（出现过「回云南」却显示 `Jun 4 – Jun 5` 仅 1 天却 `14 left` 的不一致）。
- [ ] 地球重新转角度，让国旗标签**散开不重叠**（出现过 `United…`/`Netherlands` 叠字）。
- [ ] 主题统一深色（第 6 帧除外）。
- [ ] Apple Weather 角标**保留**（Apple 强制署名，去掉违规）。
- [ ] 目的地用度假感地点（京都/巴黎/伦敦），不用「出差到 XX」。
- [ ] 截图中不出现台/港地名（首版规避大陆审核敏感，中国本国地名正常）。

---

## 6 帧脚本

### slogan 中英对照速查（做两版预览图用）

> en-US 一套、zh-Hans 一套；构图/机型/摆位完全一致，只换「界面语言 + 下方 slogan 文字」。

| # | 界面 | 中文 slogan | 英文 slogan |
|---|------|------------|------------|
| 1 | 地球 | 去过哪，它都替你记着 | Every place you've been, still with you. |
| 2 | 首页 | 每一段，都是好时光 | Time well traveled. |
| 3 | Smart picks ⭐ | 你可能遗漏的，它帮你想一想 | It thinks of what you might miss. |
| 4 | 清单 + 信息卡（电压橙标） | 该准备的，提前知道 | Pack like you've already been. |
| 5 | Widget + Live Activity | 旅行还没开始，期待已经开始 | Still days away — already can't wait. |
| 6 | 深浅对比（可砍） | 深色浅色，都好看 | Beautiful in light & dark. |

---

### 第 1 帧 — 地球（情感钩子 · 全景左半）

- **界面**：3D 卫星地球，国旗插在已访问国家上，底部「My Trips」卡片**露头**。
- **取景**：手机略向右溢出版心，为第 2 帧的「卡片拉满」做连续动作铺垫。
- **数据**：点亮 6–7 个度假国家；旗子散开不重叠。
- **slogan**：
  - 中：`去过哪，它都替你记着`
  - 英：`Every place you've been, still with you.`

### 第 2 帧 — 首页 My Trips（全景右半）

- **界面**：地球上的卡片**拉满展开**后的行程列表。
- **数据**：顶部统计 `17 All Trips · 4 Upcoming · 7 Countries`；列表为真实度假行程（已删 Test）；保留进度条与 `14 left / All packed` 等状态让其显得「在用」。
- **slogan**：
  - 中：`每一段，都是好时光`
  - 英：`Time well traveled.`

### 第 3 帧 — Smart picks 场景选择（核心差异点）⭐

> 全场最强的一帧——普通 checklist App 做不出来的画面，优先打磨。

- **界面**：Add items → Smart picks 标签选中，场景 chip 列表。
- **数据（必须露出）**：
  - **`On / near period`（经期临近提醒）** ← 决定保留。最高级的女性人群信号，长在功能里，不靠粉色。
  - `Honeymoon` / `Travelling with kids` / `Daily medication` ← 让人脑补「懂各种真实的人」。
  - `Long-haul flight` / `Cruise` / `High altitude` / `Backpacking` ← 覆盖度，显得什么场景都接得住。
- **红线**：文案只能咬「打包」，不能暗示「行程规划」（该功能未做）。保留 `Pick what you're bringing this time` / `we'll help you spot what's missing`。
- **slogan**：
  - 中：`你可能遗漏的，它帮你想一想`
  - 英：`It thinks of what you might miss.`

### 第 4 帧 — 物品清单 + 信息卡（承接第 3 帧；原第 4、5 帧合并）

> 原「天气卡」帧与「插座卡特写」帧合并为一帧。一张截图只能展示一张卡（carousel），故选差异点最强的**插座卡**当主角。

- **界面**：物品清单 + 顶部横滑信息卡停在**插座卡（电压橙标亮起）**，下接分类物品。
- **取景**：插座卡居中为主角，**天气卡 / 汇率卡左右各露半张边**，暗示横滑还有更多。
- **数据**：出国行程（`European Summer · London & Paris & Amsterdam`，230V）；**电压预警橙标亮起**（直发棒/吹风机旁）；物品换成精致打包人的样子——防晒 SPF50、分装瓶、面膜、连衣裙、转换插头等；**勾掉一部分 + 顶部进度条 ~60%**，让清单「正在被认真使用」。
- **说明**：国内 220V 不触发橙标，必须用出国行程。
- **取舍**：此方案牺牲天气卡的 7 天预报全貌（仅露边）。如更看重天气卡颜值，可反向让天气卡当主角、插座露边，但电压橙标 wow 会看不全——默认插座当主角。
- **slogan**（画面已显示「这是打包清单」，文案负责讲不明显的价值）：
  - 中：`该准备的，提前知道`
  - 英：`Pack like you've already been.`

### 第 5 帧 — Widget + Live Activity（原生融合）

> Widget（Small/Medium）与 Live Activity 均为已上线功能，可放心展示。

- **界面**：营销合成帧，一帧摆两台手机：
  - **主手机（前）= 锁屏 Live Activity**：展示一程**两天后出发**的行程 + 打包进度环。最戳「它活在我手机里」。
  - **副手机（后/侧，略小）= 桌面 1×4 + 1×1 Widget**：同一程倒计时 + 打包进度。
- **数据前提**：Live Activity 只在**一周内行程**才出现，且需「打开过物品清单」后触发。截图前把目标行程改成「starts in 2 days」，并先进一次清单页激活实时活动。
- **slogan**：
  - 中：`旅行还没开始，期待已经开始`
  - 英：`Still days away — already can't wait.`

### 第 6 帧 — 深浅对比（收尾 · 可砍）

- **界面**：首页或地球，左浅右深分屏。
- **slogan**：留白，仅小字
  - 中：`深色浅色，都好看`
  - 英：`Beautiful in light & dark.`

---

## 制作细节备忘

- 顶部一行 slogan + 截图的「Things/Tripsy 干净风」，不要堆 emoji 和花哨边框，克制即高级。
- 营销背景若做不出第 1→2 帧的连续手机效果，退而用统一纯色背景摆两台手机，也能有整体感。
- 新 App 没有奖杯/下载量等社会证明，**不要照搬 Tripsy 的「奖杯标题卡」首图**——第 1 帧必须自己扛价值。
- 一张截图只让用户接住一个信息点；三张信息卡的「全家福」放进文案，不堆进画面。

---

## 模拟数据脚本（英文 storefront 用）

> 截图前按此摆数据。全部为境外大众度假目的地，规避大陆审核敏感地名（不出现台/港地名）。

### Globe 点亮的 7 国（= 首页 `7 Countries`）

分布散开、国旗辨识度高，转任意角度都不挤：

| Country | Flag |
|---|---|
| Japan | 🇯🇵 |
| France | 🇫🇷 |
| Italy | 🇮🇹 |
| Greece | 🇬🇷 |
| Iceland | 🇮🇸 |
| Thailand | 🇹🇭 |
| New Zealand | 🇳🇿 |

### 首页 Upcoming 列表（镜头会拍到）

基准日 2026-06-02，日期往后排，状态做出「在用感」：

| Title | Cities (subtitle) | Dates | Days | Badge |
|---|---|---|---|---|
| Santorini Honeymoon | Santorini & Oia | Jun 14 – Jun 21 | 8 days | `9 left` |
| European Summer | London & Paris & Amsterdam | Jul 3 – Jul 15 | 13 days | `21 left` |
| Kyoto & Osaka | Kyoto & Osaka | Aug 9 – Aug 16 | 8 days | `All packed` |
| Bali Reset | Ubud & Canggu | Sep 5 – Sep 12 | 8 days | progress ~半 |

- `Santorini Honeymoon` 放列表顶部（蜜月+海岛，女性向+度假感最强）。
- `European Summer / London & Paris & Amsterdam` 专供**第 4 帧电压橙标**（三国全 230V，清单放直发棒/吹风机触发）。
- **第 5 帧 Live Activity** 需「两天后出发」的行程 → 截那帧时临时把某条改成 `starts in 2 days`。

### 过往行程（凑 `17 All Trips` + 点亮 globe，未必入镜）

- `Roman Holiday` — Rome & Florence (Italy)
- `Iceland Ring Road` — Reykjavík (Iceland)
- `Bangkok & Phuket` — (Thailand)
- `New Zealand Roadtrip` — Queenstown (New Zealand)
- `Paris Weekend` — Paris (France)

> 统计数字保持自洽：`7 Countries` = globe 实际点亮国家数（上面去重正好 7 国）；`17 All Trips` 随意补短途凑足，不必全起名。

### 第 4 帧物品清单的精致打包数据（向女性倾斜，藏在内容里）

- `TRAVEL DOCUMENTS`：Passport、Visa
- `SKINCARE`：Sunscreen SPF50、Travel bottles、Face masks ×5
- `ELECTRONICS`：Hair straightener（⚡ 120V→230V 橙标）、Power bank、Travel adapter
- `CLOTHING`：Dress、Swimsuit、Sandals
- 勾掉一部分 + 顶部进度条 ~60%，让清单「正在被认真使用」。
