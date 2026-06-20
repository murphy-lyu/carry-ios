# carry-config Worker（远程配置代发）

把 carry-ios 仓库的静态配置（`roadmap.json`）经自营域名 **`config.nevestudio.app`** 发出来，
让中国大陆无 VPN 也能拉到（`raw.githubusercontent.com` 被 GFW 阻断）。

- **真源**：`carry-ios` 仓库根的 `roadmap.json`（不搬家）。本 Worker 只回源 + 缓存，不存内容。
- **加载链路**：App → `config.nevestudio.app/roadmap.json`（Worker）→ 回源 `raw.githubusercontent.com/.../main/roadmap.json`（墙外）→ 缓存 5 分钟。
- **白名单**：只代发 `/roadmap.json`，其余 404（防被当开放代理）。

## 部署（Cloudflare 控制台）

1. **Workers & Pages → Create application → Create a Worker**（Start with Hello World!）。
2. 命名 `carry-config` → 创建后 **Edit code** → 把 `worker.js` 全文粘进去 → **Deploy**。
3. 进该 Worker 的 **Domains/Settings → Add Custom Domain** → 填 `config.nevestudio.app` → 等 Active。

## 验证

```
curl -s -o /dev/null -w "%{http_code}\n" https://config.nevestudio.app/roadmap.json   # 期望 200
```

## 改 roadmap 的流程（不变）

照常改 **`carry-ios/roadmap.json`** 并 push。Worker 缓存 5 分钟，过后自动反映最新。
（验证 main 是否更新仍用 GitHub API：`https://api.github.com/repos/murphy-lyu/carry-ios/contents/roadmap.json?ref=main`。）
