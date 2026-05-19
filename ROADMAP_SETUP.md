# Roadmap Remote Setup (GitHub)

This app already supports remote Roadmap updates without releasing a new app version.

## Quick setup (5 minutes)

1. Create a file in any public GitHub repo, for example:
   - `roadmap.json`
2. Copy content from `roadmap.sample.json` and paste into your new `roadmap.json`.
3. Open the file on GitHub and click `Raw`.
4. Copy the raw URL. It should look like:
   - `https://raw.githubusercontent.com/<user>/<repo>/<branch>/roadmap.json`
5. In the app:
   - `Settings -> Roadmap -> top-right link icon`
   - Paste the URL and tap `Save`
6. Pull down to refresh in Roadmap page.

## Notes

- If remote fetch fails, app falls back to local cache.
- If cache is also empty, app shows embedded default roadmap data.
- You can leave URL empty to always use embedded default data.

## JSON format

```json
{
  "updatedAt": "2026-05-20",
  "banner": "🚀 App Store 上线，2026年7月",
  "sections": [
    {
      "id": "upcoming",
      "title": "即将推出的更新",
      "items": [
        { "id": "ai-pack", "title": "AI 打包建议", "status": "in_progress", "note": "部分功能需要 Luggage+" }
      ]
    },
    {
      "id": "done",
      "title": "已完成",
      "items": [
        { "id": "currency", "title": "货币换算", "status": "done" }
      ]
    }
  ]
}
```

Allowed `status` values:
- `planned`
- `in_progress`
- `done`
