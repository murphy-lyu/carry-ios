# Carry 基建总览（外部服务 / 域名 / Worker / 密钥 / 排查）

> 单一真源：Carry 依赖的所有**外部服务、自营域名、Cloudflare Worker、密钥、云控开关**都记在这。
> 遇到「国内连不上 / 搜不到 / 翻译失效 / 通知不准」先来这查。账号主体：`murphy.lyu@hotmail.com`（Cloudflare/Azure）、`murphy-lyu`（GitHub/Mapbox）。

## 1. 自营域名（`nevestudio.app`，Cloudflare Registrar 注册）

工作室品牌 = **Neve**（`nevestudio.app`）。按功能分子域，各司其职：

| 子域 | 用途 | 背后 |
|---|---|---|
| `flight.nevestudio.app` | 航班号查询代理 | Worker `carry-flight` |
| `config.nevestudio.app` | App 远程配置（roadmap.json 代发） | Worker `carry-config` |
| `places.nevestudio.app` | 海外地点检索代理 | Worker `carry-places` |
| `legal.nevestudio.app` | 隐私/用户协议页 | Cloudflare Pages（接 `carry-legal` 仓库） |

> 为什么要自营域名：`*.workers.dev` / `github.io` / `raw.githubusercontent.com` 在**中国大陆被 GFW 干扰**，无 VPN 不可达；自营域名（Cloudflare）国内可达。详见 [[carry-neve-studio-brand-and-flight-proxy]] 记忆。

## 2. Cloudflare Workers（源码在 `scripts/`）

| Worker | 源码 | 部署 | 上游 | 密钥(secret) | 云控变量(vars) |
|---|---|---|---|---|---|
| `carry-flight` | `scripts/flight-proxy/worker.js` | 后台粘贴 | AeroDataBox（经 RapidAPI） | `MARKET_KEY`、`APP_TOKEN` | `KEY_HEADER`/`UPSTREAM_BASE`/`UPSTREAM_HOST`/`CACHE_TTL_SECONDS` |
| `carry-config` | `scripts/config-proxy/worker.js` | 后台粘贴 | GitHub raw（carry-ios/roadmap.json） | 无 | 无 |
| `carry-places` | `scripts/places-proxy/`（wrangler 工程） | **wrangler**（打包 tz-lookup） | Mapbox Search Box（主）+ Geoapify（备）+ Azure Translator | `MAPBOX_TOKEN`、`GEOAPIFY_KEY`、`APP_TOKEN`、`AZURE_TRANSLATOR_KEY` | `OVERSEAS_POLICY`、`SEARCH_PROVIDER`、`AZURE_TRANSLATOR_REGION` |

- `carry-places` 改完重部署：`cd scripts/places-proxy && npx wrangler deploy`（先 `npm install` + `npx wrangler login`）。
- 设/换 secret：`npx wrangler secret put <NAME>`（值等提示符出现再粘）。
- **云控开关 `OVERSEAS_POLICY`**：`all`（默认，都开）/ `cn_only`（仅大陆 storefront）/ `off`（全关）。改 `wrangler.toml` 后 `deploy`；或后台 Settings→Variables 即时改（但下次 deploy 会被 wrangler.toml 覆盖，记得同步）。
- **云控开关 `SEARCH_PROVIDER`**：`auto`（默认，Mapbox 主 + Geoapify 自动降级，主源**硬失败**才切）/ `mapbox`（仅主）/ `geoapify`（仅备）。Mapbox 出问题（额度/故障）时改这里即切到 Geoapify，零发版救老用户。suggest 结果 id 带 `mb:`/`ga:` 前缀，`/retrieve` 据此路由回正确来源；Geoapify 把 retrieve 所需数据塞进 id（base64url），离线解析、不二次请求。
  - ⚠️ **接入 Mapbox / Geoapify 之外的新服务商时，必须同步更新隐私政策的服务商名单**（carry-legal `privacy/zh.html` + `privacy/index.html` 第 5 节「地点检索」段，现列举「Mapbox 或 Geoapify」）——否则会出现「实际把检索词发给了未披露的第三方」的合规失真。这是「列举式披露」的唯一维护点。

## 3. 第三方服务

| 服务 | 用途 | 账号/计费 | 备注 |
|---|---|---|---|
| **AeroDataBox**（RapidAPI） | 航班号 → 航线/时刻/机型 | RapidAPI | 上架前切 API.market 商用档（仅改 Worker 变量） |
| **Apple MapKit / 高德** | **国内**地点检索（`MKLocalSearchCompleter`） | 系统内置 | 大陆设备后端=高德，只覆盖中国+港澳；海外搜不到（故有 Mapbox） |
| **Mapbox**（Search Box） | **海外**地点检索（主源） | Mapbox（F0 免费额度） | token 在 `carry-places` 的 `MAPBOX_TOKEN`；只用境外结果（合规）；按 session 计费（App 端 retrieve 后轮换 session） |
| **Geoapify**（Geocoding Autocomplete） | **海外**地点检索（备份源，防 Mapbox 单点） | Geoapify（免费档 ~3000 请求/天） | key 在 `carry-places` 的 `GEOAPIFY_KEY`；`SEARCH_PROVIDER` 决定是否启用；autocomplete 单次带坐标，retrieve 离线解析 |
| **Azure AI Translator**（F0） | 海外检索的**中文→英文**翻译 | Azure（F0 永久免费 200 万字/月） | region `eastasia`；海外 POI 无中文别名，故中文 query 先翻英文（两源共用） |

> 不用 Google/DeepL/中国源的原因：DeepL 绑卡受限、Google 在华敏感、用户倾向非中国源。provider 都藏在 Worker 后，**换它只改 Worker、App 不动**。

## 4. App 内密钥（`Carry/Resources/Secrets.plist`，**gitignored**）

| 键 | 对应 Worker secret | 用途 |
|---|---|---|
| `FlightProxyAppToken` | carry-flight 的 `APP_TOKEN` | 调航班代理的门槛 |
| `PlacesProxyAppToken` | carry-places 的 `APP_TOKEN` | 调地点代理的门槛 |

- **此文件不进 git**：换电脑 / CI 必须重建，否则航班/海外检索的 `X-App-Token` 为空、被 Worker 401。
- 真正的上游 key（Mapbox/Azure/AeroDataBox）**只在 Worker secret**，永不进 App/git。
- 低安全级门槛 token，泄露走**轮换**（Worker secret + Secrets.plist 同步换新）。

## 5. 排查指引（症状 → 先查这里）

- **国内无 VPN 某功能拿不到数据**：确认 App 调的是**自营子域**（非 `*.workers.dev`/`github.io`）；curl 该子域看是否 200。
- **海外地点搜不到 / 搜中文没结果**：① `places.nevestudio.app/suggest` 带 `X-App-Token` curl；② 中文搜不到 → Azure key/额度（翻译失败会回退原中文→多半空）；③ 全空 → 查 `OVERSEAS_POLICY` 是否被切成 `cn_only`/`off`。
- **航班查不到**：`flight.nevestudio.app/flight?...` curl；401=app-token 不符；502=上游/额度。
- **隐私/路线图页打不开或没更新**：legal/config 走 Pages/Worker，push 后约 5 分钟缓存；用 GitHub API 确认 main 已更新。
- **新电脑构建后航班/海外失效**：多半 `Secrets.plist` 没重建（见 §4）。

## 6. 待办 / 加固（非阻塞）
- ✅ 海外检索**备份源**（Geoapify）+ `SEARCH_PROVIDER` 云控自动降级：已接（2026-06-21）。防 Mapbox 单点，换源零发版。
- ✅ 账单告警：Azure Budgets（$1 阈值 80%/邮件）已设；Mapbox 接近免费额度自动邮件提醒。
- Mapbox/Azure/Geoapify 账号邮箱已验证。
