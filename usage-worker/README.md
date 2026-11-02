# Usage count server

A Cloudflare Worker with a D1 table that counts active Lip Service installs. The app side is `DictationCore/Sources/DictationCore/UsageCount.swift`, and the README's Privacy section lists what it sends.

- `POST /v1/ping` takes one report. It stores a report that has exactly the five fields, and ignores anything else with a 400. A second report for the same install and day changes nothing. The Worker never reads the request's IP address, and `wrangler.toml` turns request logging off.
- `GET /v1/stats` needs `Authorization: Bearer <READ_TOKEN>`. It returns the active installs today, over 7 days and over 30 days, installs by version over 7 days, all installs ever seen, and a daily table for 30 days.

```sh
curl -H "Authorization: Bearer $LIPSERVICE_USAGE_READ_TOKEN" https://lipservice-usage.hunterbohm.me/v1/stats
```

The token is `LIPSERVICE_USAGE_READ_TOKEN` in Infisical `/agents`, and the Worker's `READ_TOKEN` secret holds the same value.

Test with `npm test`. Deploy with `wrangler deploy` and create the table once with `wrangler d1 execute lipservice-usage --remote --file schema.sql`.
