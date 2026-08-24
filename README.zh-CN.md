# product-trend-data

[English](README.md) | [中文](README.zh-CN.md)

发布到 GitHub Pages 的静态 JSON：按零售商、按商品记录的公开价格历史。这就是
`../Price Trend Extension` 默认读取的数据
（`https://runnan-pan.github.io/product-trend-data`）。由 `scripts/` 里的定时
任务生成并推送——`v1/` 下的内容不应该手工编辑。

## 目录结构

```
v1/{retailer}/manifest.json
v1/{retailer}/products/{id}/history.json
```

`{retailer}` 是各后端发布的 API 路径段，例如 `chemist_warehouse`、
`bunnings_warehouse`。每个后端仓库（`../Chemist Warehouse Trend`、
`../Bunnings Warehouse Trend` 等）各自负责采集和数据库；本仓库只放它们导出
的结果。

## 定时任务

采集（去碰零售商网站）和发布（把本地数据库变成本仓库的 JSON 并推送）是两件
分开的事，分别调度：

| 脚本 | 做什么 | 调度方式 |
| --- | --- | --- |
| `scripts/collect_loop.sh <后端仓库路径>` | 一直循环：在该后端仓库里跑 `make sitemap` 再 `make collect`，一轮接一轮。不导出 JSON，也不碰 git。 | launchd `KeepAlive`，每个零售商一个 agent |
| `scripts/publish.sh` | 对每个零售商跑 `make export-static`，写进本仓库，然后在这里做一次 `git add/commit/push`。不碰零售商网站。 | launchd，每天 08:00 |

`collect_loop.sh` 每个零售商各起一个 agent（`com.pricetrend.collect-chemist.plist`、
`com.pricetrend.collect-bunnings.plist`），两边可以同时跑，各自只碰自己后端的
`prices.db`。一轮指一次 `make sitemap` + `make collect`。一轮结束后：

- **被拦截**（403/429/503，或者拉 sitemap 本身就失败了）：退避 1 小时再重试。
- **没有待办**（当天该抓的都已经抓过——每个后端本来就是一天一份快照）：休眠到
  下一个 Australia/Sydney 日，不然只是在空转重复拉 sitemap。
- **有实际进展**：立刻开始下一轮。

两个脚本各自在 `/tmp` 下用锁文件防止重复启动的实例（launchd 二次拉起或手动
测试跑）互相冲突。抓完整个目录要跑好几个小时，所以 `collect_loop.sh` 在自己
存活期间会一直跑 `caffeinate`——这两个采集 agent 就是设计成加载期间让 Mac 一直
保持唤醒。

安装：

```bash
cp scripts/com.pricetrend.collect-chemist.plist scripts/com.pricetrend.collect-bunnings.plist scripts/com.pricetrend.publish.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.pricetrend.collect-chemist.plist
launchctl load ~/Library/LaunchAgents/com.pricetrend.collect-bunnings.plist
launchctl load ~/Library/LaunchAgents/com.pricetrend.publish.plist
```

卸载：`launchctl unload ~/Library/LaunchAgents/com.pricetrend.*.plist`，
再删掉拷贝过去的文件。日志放在脚本旁边：`scripts/collect-*.log` /
`scripts/publish.log`（脚本自己写的）和 `scripts/launchd.*.log`（launchd 的
标准输出/错误）——两者都在 `.gitignore` 里，`publish.sh` 的 `git add -A`
不会把它们带进去。

## 新增零售商

1. 让新零售商的后端仓库具备跟现有仓库一样的 `make sitemap` / `make collect` /
   `make export-static` 目标。
2. 把它的名字加进 `scripts/publish.sh` 的 `RETAILERS` 数组。
3. 复制一份 `com.pricetrend.collect-*.plist`，指向新的后端仓库，再加载它。

`scripts/collect_loop.sh` 和 `scripts/publish.sh` 的核心逻辑不用改——两者都
和具体零售商无关。
