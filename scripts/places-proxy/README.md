# carry-places Worker（海外地点检索代理）

代理 Mapbox Search Box，让大陆设备也能搜海外地点；**只服务境外**（中国境内交给高德，合规）；
坐标→IANA 时区随结果返回；运控策略 `OVERSEAS_POLICY` 可在后台即时切。spec: `specs/itinerary-overseas-poi-search.md`。

> ⚠️ 与航班/config Worker 不同，本 Worker 要打包 `tz-lookup`（坐标转时区），**走 wrangler 部署**（不是后台粘贴）。

## 部署（你来，一次性）

```bash
cd scripts/places-proxy
npm install                 # 装 wrangler + tz-lookup
npx wrangler login          # 浏览器授权（和你 Cloudflare 同账号）

# 设密钥（不进 git）：
npx wrangler secret put MAPBOX_TOKEN   # 粘贴 carry-places-worker 那个 token（pk....）
npx wrangler secret put APP_TOKEN      # 随便一串长随机值；要和 App 里 Secrets.plist 的对应（见下）

npx wrangler deploy         # 部署
```

部署后在 **Cloudflare 后台 → Workers → carry-places → Domains → Add Custom Domain** 绑 **`places.nevestudio.app`**（和航班一样）。

## 验证

```bash
# 期望 401（没带 app-token，证明 Worker 在线 + 鉴权生效）
curl -s -o /dev/null -w "%{http_code}\n" "https://places.nevestudio.app/suggest?q=eiffel"
# 带 token + storefront：应返回巴黎等境外结果（中国境内被过滤）
curl -s -H "X-App-Token: <你的APP_TOKEN>" "https://places.nevestudio.app/suggest?q=eiffel&storefront=CHN&language=zh" | head -c 400
```

## 运控（成本控制）
`OVERSEAS_POLICY`：`all`（都开，默认）| `cn_only`（仅大陆）| `off`（全关）。
改它无需 App 发版：改 `wrangler.toml` 后 `npx wrangler deploy`，或后台 Settings → Variables 直接改。

## App 侧对应
- App 调 `https://places.nevestudio.app/suggest` + `/retrieve`，带 `X-App-Token`（存 gitignore 的 `Carry/Resources/Secrets.plist`，键如 `PlacesProxyAppToken`，同航班 token 范式）。
- `OVERSEAS_POLICY` 切换对 App 透明（返回空时 App 自然只剩高德结果）。
