#!/usr/bin/env bash
# verify.sh — NewAPI OpenResty sidecar 回归自检（fail-closed 版）
# 原则：任何一项拿不到「正面证据」= FAIL。不再容忍 "无输出=通过" 这类假通过。
#       2026-09-21 事故教训：旧版在 sidecar 挂死时因 curl 超时→文件缺失→检查脚本崩溃→空输出被判 PASS。
# 2026-09-21 二期改动：条件归并(6个) + 合成名显示/改写(23个)。合成对直接从 conf 解析（防漂移）。
# 注意：刚 reload 部署后，/v1/models 缓存 TTL=30s，请等 ~35s 再跑本脚本。
# 用法: bash verify.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TOK=$(docker exec postgres psql -U root -d new-api -t -A -c "SELECT key FROM tokens WHERE id=1 LIMIT 1;" | tr -d ' ')
[ -n "$TOK" ] || { echo "FATAL: 拿不到 API token，无法继续"; exit 2; }
T=$(mktemp -t napi-verify.XXXXXX)
trap 'rm -f "$T" "$T.clean" "$T.raw"' EXIT

# 1) 生效配置
docker exec openresty sh -c '/usr/local/openresty/bin/openresty -t' >/dev/null 2>&1 && ok "nginx -t 语法通过" || bad "nginx -t 失败"
docker exec openresty sh -c '/usr/local/openresty/bin/openresty -T 2>/dev/null | grep -q "lua_shared_dict model_cache"' && ok "lua_shared_dict 在生效配置" || bad "lua_shared_dict 缺失"
docker exec openresty sh -c '/usr/local/openresty/bin/openresty -T 2>/dev/null | grep -q "MODELNORM"' && ok "MODELNORM 区块在生效配置" || bad "MODELNORM 区块缺失"

# 1.5) CPU 死循环哨兵（事故模式：Lua 死循环会把 nginx worker 打满到 ~100%）
CPU=$(docker stats openresty --no-stream --format '{{.CPUPerc}}' 2>/dev/null | tr -d ' %')
CPU_INT=${CPU%%.*}
if [ -n "$CPU_INT" ] && [ "$CPU_INT" -lt 50 ]; then ok "CPU 正常(${CPU}%)"; else bad "CPU 异常(${CPU:-?}%)，疑似死循环"; fi

# 2) 列表契约（sidecar :3000 vs 直连 :3001）— fail-closed
RC1=0; T1=$(curl -s -m 12 -w '%{time_total}' -o "$T.clean" -H "Authorization: Bearer $TOK" http://127.0.0.1:3000/v1/models) || RC1=$?
RC2=0; curl -s -m 12 -o "$T.raw" -H "Authorization: Bearer $TOK" http://127.0.0.1:3001/v1/models || RC2=$?
if   [ $RC1 -ne 0 ]; then bad "sidecar /v1/models 请求失败(curl exit=$RC1 超时保护触发)"
elif [ ! -s "$T.clean" ]; then bad "sidecar /v1/models 返回空"
else ok "sidecar /v1/models 可达(${T1}s)"; fi
if   [ $RC2 -ne 0 ]; then bad "直连 /v1/models 请求失败(curl exit=$RC2)"
elif [ ! -s "$T.raw" ]; then bad "直连 /v1/models 返回空"
else ok "直连 /v1/models 可达"; fi

if [ $RC1 -eq 0 ] && [ $RC2 -eq 0 ] && [ -s "$T.clean" ] && [ -s "$T.raw" ]; then
  LIVE=$(docker exec postgres psql -U root -d new-api -t -A -c "SELECT DISTINCT a.model FROM abilities a JOIN channels c ON a.channel_id=c.id WHERE c.status=1;")
  V=$(python3 - "$T.clean" "$T.raw" "$LIVE" "$HERE/openresty/default.conf" <<'PY'
import json, sys, re
from collections import defaultdict
try:
    clean = [m['id'] for m in json.load(open(sys.argv[1]))['data']]
    raw   = [m['id'] for m in json.load(open(sys.argv[2]))['data']]
except Exception as e:
    print(f"CHECKER_EXC: 列表解析失败: {e}"); raise SystemExit(0)
live = set(x.strip() for x in sys.argv[3].splitlines() if x.strip())

# —— 合成名表：直接从生效 conf 解析（conf 是唯一事实源，防校验副本漂移）——
conf = open(sys.argv[4], encoding='utf-8').read()
mb = conf.find('>>>SYNTH_BEGIN'); me = conf.find('<<<SYNTH_END')
pairs = {}
if mb > 0 and me > mb:
    for d, t in re.findall(r'\["([^"]+)"\]\s*=\s*"([^"]+)"', conf[mb:me]):
        pairs[d] = t

fails = []
if not clean: fails.append("clean列表为空")
if not raw: fails.append("raw列表为空")
if clean and raw and len(clean) > len(raw): fails.append(f"clean({len(clean)})>raw({len(raw)})")
def ultra(s): return re.sub(r'[^a-z0-9]', '', s.lower())
g = defaultdict(list)
for i in clean: g[ultra(i)].append(i)
dups = [v for v in g.values() if len(v) > 1]
if dups: fails.append(f"残余同款:{dups[:2]}")

# 死名检查：合成名（显示层别名）豁免；其余必须在活渠道
dead = [m for m in clean if m not in live and m not in pairs]
if dead: fails.append(f"无活渠道:{dead[:2]}")

# 合成对断言：显示名在列表 / 真实名已藏 / 真实名有活渠道 / 显示名非上游真名
if len(pairs) < 10: fails.append(f"合成表解析异常(条数={len(pairs)})")
for d, t in sorted(pairs.items()):
    if d not in clean: fails.append(f"合成名缺失:{d}")
    if t in clean: fails.append(f"合成真实名未藏:{t}")
    if t not in live: fails.append(f"合成目标无活渠道:{t}")
    if d in raw: fails.append(f"合成名撞上游真名:{d}")

# 抽样折叠对（仅当原始列表同时含两者时断言）
for show, hide in [('glm-5.3-flash','z-ai/glm-5.3-flash'),
                   ('gemma-4-31b-it','gemma-4-31b-it:free'),
                   ('deepseek-v4-flash','deepseek-v4-flash-0731'),
                   ('glm-5.2','glm-5.2-thinking'),
                   ('deepseek-v4.1-flash','deepseek-v4.1-flash-1'),
                   ('glm-5.2','glm-5.2-200k'),
                   ('glm-5.3','glm-5.3-200k'),
                   ('hy3','hy3-preview'),
                   ('gemini-3.5-flash','gemini-3.5-flash-lite'),
                   ('senseaudio-s2','SenseAudio-S2-Lite')]:
    if show in raw and hide in raw:
        if hide in clean: fails.append(f"应藏仍在:{hide}")
        if show not in clean: fails.append(f"应留缺失:{show}")
print("|".join(fails) if fails else "OK")
PY
)
  case "$V" in
    OK)  ok "列表契约(无残余同款/全可路由/合成对/抽样折叠对)" ;;
    "")  bad "契约检查无输出(检查脚本异常，按 FAIL 处理)" ;;
    *)   bad "$V" ;;
  esac
else
  bad "列表契约: 前置请求失败，跳过"
fi

# 3) 端到端 chat（走 sidecar :3000 真实路径，含超时保护）
for M in "deepseek-v4-flash-0731" "deepseek-v4-flash"; do
  B="{\"model\":\"$M\",\"messages\":[{\"role\":\"user\",\"content\":\"写一句关于春天的短句。\"}],\"max_tokens\":16}"
  RC=0; R=$(curl -s -m 60 -X POST http://127.0.0.1:3000/v1/chat/completions -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" -d "$B") || RC=$?
  if [ $RC -ne 0 ] || [ -z "$R" ]; then bad "E2E[$M]: 无响应(exit=$RC)"
  elif echo "$R" | grep -q '"choices"'; then ok "E2E[$M]: 正常生成"
  elif echo "$R" | grep -qE '"(error|base_resp)"'; then ok "E2E[$M]: 上游业务提示(链路通)"
  else bad "E2E[$M]: 响应异常 ${R:0:80}"; fi
done

# 3.5) 合成名改写端到端 —— 断言"上游看到了真实名"（双探针，任一命中即通过；防单探针偶发慢）
#  探针A deepseek-v4-flash-vision：CPA 当前报 unknown provider 且回显真名（快、稳）
#  探针B hy4：正常生成且回显真名（偶发上游慢）
REWRITE_OK=0; REWRITE_NOTE="(未执行)"
for PROBE in "deepseek-v4-flash-vision:deepseek-v4-flash-vision-exp" "hy4:hy4-preview"; do
  M="${PROBE%%:*}"; REAL="${PROBE##*:}"
  B="{\"model\":\"$M\",\"messages\":[{\"role\":\"user\",\"content\":\"say OK\"}],\"max_tokens\":8}"
  RC=0; R=$(curl -s -m 60 -X POST http://127.0.0.1:3000/v1/chat/completions -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" -d "$B") || RC=$?
  if echo "$R" | grep -q "$REAL"; then REWRITE_OK=1; REWRITE_NOTE="$M -> $REAL"; break; fi
  if [ $RC -ne 0 ]; then REWRITE_NOTE="probe[$M] 超时"; else REWRITE_NOTE="probe[$M] 无名字证据"; fi
done
if [ "$REWRITE_OK" = "1" ]; then ok "改写E2E: 翻译证据($REWRITE_NOTE)"
else bad "改写E2E: 未获翻译证据($REWRITE_NOTE)"; fi

# 4) 容器健康
for c in openresty new-api; do
  st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c")
  [ "$st" = "healthy" ] && ok "$c healthy" || bad "$c=$st"
done

echo "== 汇总: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
