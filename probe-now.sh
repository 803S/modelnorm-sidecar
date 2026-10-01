#!/bin/bash
# probe-now.sh — 手动触发 new-api 模型探活
#
# 用法：
#   ./probe-now.sh          立刻触发一轮（后台循环内，跑完自动继续等间隔）
#   ./probe-now.sh --once   前台跑完一整轮然后退出（适合看完整输出）
#   ./probe-now.sh --status 查看健康表统计（dead/suspect/unknown）
#
# 说明：探活结果写入 sidecar 健康表；被判定 dead 的模型会从 /v1/models 隐藏。
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-trigger}"

case "$MODE" in
  --once|-o)
    echo "== 前台跑完一整轮（约 10-20 分钟，含慢模型超时）=="
    docker exec prober /app/probe.sh --once
    ;;
  --status|-s)
    echo "== 健康表统计 =="
    docker exec prober sh -c '
      curl -s -m 10 "http://openresty:3000/__modelnorm/health/list" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}"' \
      | python3 -c '
import sys, json
d = json.load(sys.stdin)
from collections import Counter
c = Counter()
for e in d.get("entries", []):
    try:
        c[json.loads(e["val"]).get("status", "?")] += 1
    except Exception:
        c["bad"] += 1
print("总计:", d.get("count"), dict(c))
'
    ;;
  *)
    echo "== 触发一轮探活（不打断后台循环）=="
    docker exec prober touch /tmp/probe_now
    echo "已触发，约 30 秒内开始；用 docker logs -f prober 观察"
    ;;
esac
