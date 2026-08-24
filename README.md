# product-trend-data

[English](README.md) | [中文](README.zh-CN.md)

Static JSON published to GitHub Pages: recorded public price history per
retailer, per product. This is the data `../Price Trend Extension` reads by
default (`https://runnan-pan.github.io/product-trend-data`). It is generated
and pushed by the scheduled tasks in `scripts/` — nothing under `v1/` should
be hand-edited.

## Layout

```
v1/{retailer}/manifest.json
v1/{retailer}/products/{id}/history.json
```

`{retailer}` is the API path segment each backend publishes, e.g.
`chemist_warehouse`, `bunnings_warehouse`. Each backend repo
(`../Chemist Warehouse Trend`, `../Bunnings Warehouse Trend`, ...) owns its
own collector and database; this repo only holds their exported output.

## Scheduled tasks

Collecting (hitting a retailer site) and publishing (turning the local
database into this repo's JSON and pushing it) are two separate concerns,
scheduled separately:

| Script | What it does | Schedule |
| --- | --- | --- |
| `scripts/collect_loop.sh <backend-repo>` | Runs forever: `make sitemap` then `make collect` in that backend repo, round after round. Never exports JSON or touches git. | launchd `KeepAlive`, one agent per retailer |
| `scripts/publish.sh` | `make export-static` for every retailer, writing into this repo, then one `git add/commit/push` here. Never touches a retailer site. | launchd, daily at 08:00 |

There is one `collect_loop.sh` agent per retailer (`com.pricetrend.collect-chemist.plist`,
`com.pricetrend.collect-bunnings.plist`) so both collectors run at the same
time, each against its own backend's `prices.db`. A round is one
`make sitemap` + `make collect` pass. When a round ends:

- **blocked** (403/429/503, or the sitemap fetch itself failed): back off 1
  hour before trying again.
- **nothing pending** (everything for today was already collected — each
  backend keeps one snapshot per calendar day): sleep until the next
  Australia/Sydney day instead of looping pointlessly on the sitemap.
- **made progress**: start the next round immediately.

Each script takes its own lock file under `/tmp` so a second launchd start
(or a manual test run) doesn't overlap a running instance. Collecting a full
catalog runs for hours, so `collect_loop.sh` runs `caffeinate` for as long as
it's alive — the collect agents are meant to keep the Mac awake continuously
while loaded.

Install:

```bash
cp scripts/com.pricetrend.collect-chemist.plist scripts/com.pricetrend.collect-bunnings.plist scripts/com.pricetrend.publish.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.pricetrend.collect-chemist.plist
launchctl load ~/Library/LaunchAgents/com.pricetrend.collect-bunnings.plist
launchctl load ~/Library/LaunchAgents/com.pricetrend.publish.plist
```

Uninstall: `launchctl unload ~/Library/LaunchAgents/com.pricetrend.*.plist`
then remove the copied files. Logs land next to the scripts:
`scripts/collect-*.log` / `scripts/publish.log` (script-level) and
`scripts/launchd.*.log` (launchd stdout/stderr) — both are gitignored, so
`publish.sh`'s `git add -A` never picks them up.

## Add a new retailer

1. Give the new retailer's backend repo the same `make sitemap` / `make
   collect` / `make export-static` targets as the existing ones.
2. Add its name to the `RETAILERS` array in `scripts/publish.sh`.
3. Copy one of the `com.pricetrend.collect-*.plist` files, point it at the
   new backend repo, and load it.

No change needed in `scripts/collect_loop.sh` or `scripts/publish.sh`'s core
logic — both are retailer-agnostic.
