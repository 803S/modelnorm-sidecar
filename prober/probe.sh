#!/bin/bash
# probe.sh — 探活容器主脚本
#
# 每轮对 /app/models.txt 中模型各发 1 个 max_tokens=1 的 POST :3000，
# 判定结果写入 sidecar 的 health 表（/__modelnorm/health）。
#
# 判定原则（fail-open）：
#   - curl 超时/网络错误 = UNKNOWN（首次响应慢≠死，2026-09-24 glm-5.1 误判教训）
#   - 只有连续 2 轮都拿到明确 error 响应才标 dead
#   - dead 会被 /v1/models 过滤；suspect/unknown 不过滤（仅记录）
#
# 环境变量：
#   GATEWAY_URL   默认 http://openresty:3000
#   MODEL_LIST    默认 /app/models.txt
#   SLEEP         轮次间隔秒数，默认 14400（4 小时）+ 0~900s 随机抖动
#   PROBE_PAUSE   每个模型之间的基础间隔秒数，默认 2（+0~2s 抖动）
#                 → 一轮 173 个约 6~10 分钟打完，速率约 0.3~0.5 req/s
#                 目的：避免突发流量吃光上游并发额度导致用户侧 429
#   BATCH_SIZE    每探测多少个模型长休一次，默认 25
#   BATCH_PAUSE   长休秒数，默认 12（+0~15s 抖动）
#   TRIGGER_FILE  手动触发哨兵文件，默认 /tmp/probe_now（存在即立刻跑一轮）
#
# 静默时段：本地 00:00-08:00 不探活（脚本内按 UTC>=16 判定）
# 手动探活：
#   立刻触发一轮（后台循环内）: docker exec prober touch /tmp/probe_now
#   前台跑完一轮即退出:         docker exec prober /app/probe.sh --once
#   ADMIN_TOKEN   默认 health-admin-token（需与 default.conf 一致）
#   TOKEN         new-api 鉴权 token（必填）

set -eu

GATEWAY_URL="${GATEWAY_URL:-http://openresty:3000}"
MODEL_LIST="${MODEL_LIST:-/app/models.txt}"
SLEEP="${SLEEP:-14400}"
export ADMIN_TOKEN="${ADMIN_TOKEN:-health-admin-token}"

# ---------------- 限速参数（防突发吃光上游并发 → 用户侧 429）----------------
PROBE_PAUSE="${PROBE_PAUSE:-2}"
BATCH_SIZE="${BATCH_SIZE:-25}"
BATCH_PAUSE="${BATCH_PAUSE:-12}"
# 被动优先模式：1=只主动探测盲区模型（默认），0=全量主动探活
ONLY_BLIND="${ONLY_BLIND:-1}"
PASSIVE_ENABLED="${PASSIVE_ENABLED:-1}"
TOKEN="${TOKEN:-}"
STATE_DIR="/tmp/probe_state"
TRIGGER_FILE="${TRIGGER_FILE:-/tmp/probe_now}"   # 手动触发哨兵：touch 此文件即立刻跑一轮

[ -z "$TOKEN" ] && { echo "FATAL: TOKEN env is required (new-api bearer token)" >&2; exit 1; }
mkdir -p "$STATE_DIR"

die() { echo "FATAL: $*" >&2; exit 1; }

state_key() { echo "$STATE_DIR/$(echo "$1" | md5sum | cut -d' ' -f1)"; }

# 探活单个模型（超时 90s，上游链路慢是常态）
# 返回: LIVE|DEAD|UNKNOWN
# 探活提示词池：自然短句，避免短消息命中上游反测活关键词（如 "ping"）。
# 输出控制：每个提示词都明确要求短输出（≤30字/单词），既拟真又省 token。
PROBE_PROMPTS=(
    "用一句话概括今天天气很好。"
    "翻译：你好世界。"
    "给我一个两个字的中文回复：在吗？"
    "请回复：好。"
    "把数字 1 翻译成中文。"
    "请输出一个字：好。"
    "简短问候：回我一句早安。"
)
probe_one() {
    local model="$1"
    local body rc=0
    # 随机选一条提示词，让每轮探活流量看起来不一样
    local prompt="${PROBE_PROMPTS[$RANDOM % ${#PROBE_PROMPTS[@]}]}"
    body=$(curl -s -m 90 -X POST "${GATEWAY_URL}/v1/chat/completions" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"${prompt}\"}],\"max_tokens\":8}") || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "UNKNOWN"; return   # 超时/网络错误 ≠ 死
    fi
    if echo "$body" | grep -q '"choices"'; then
        echo "LIVE"
    elif echo "$body" | grep -q '"error"'; then
        echo "DEAD"
    else
        echo "UNKNOWN"
    fi
}

# 写入健康表（连续 2 轮 DEAD 才写 dead；单轮 DEAD 写 suspect）
write_health() {
    local model="$1" verdict="$2"
    local key prev
    key=$(state_key "$model")
    prev=$(cat "$key" 2>/dev/null || echo "")
    echo "$verdict" > "$key"

    local status
    case "$verdict" in
        LIVE)    status="live";;      # 活就是活（原写 suspect，导致活模型被当可疑、死模型降级后无法区分）
        DEAD)    [ "$prev" = "DEAD" ] && status="dead" || status="suspect";;
        # 超时/空响应（上游挂起）：单轮不判死防抖动，连续 2 轮判死。
        # 与 429 不同 —— 429 是「稍后再来」，上游挂起对用户体验就是「不能用」，
        # 且这类模型根本不会进 new-api 的错误日志，被动检测永远看不到它们。
        UNKNOWN) [ "$prev" = "UNKNOWN" ] && status="dead" || status="unknown";;
        *)       status="unknown";;
    esac

    curl -s -m 10 -X PUT "${GATEWAY_URL}/__modelnorm/health?model=${model}" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${model}\",\"status\":\"${status}\"}" >/dev/null 2>&1 || true
    echo "$status"
}

main() {
    [ -f "$MODEL_LIST" ] || die "Model list not found: $MODEL_LIST"
    command -v curl >/dev/null 2>&1 || die "curl not found in container"

    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Starting cycle (gateway=$GATEWAY_URL)"

    # ========== 阶段 1：被动健康检测（零请求，只读 new-api 日志）==========
    local blind_file="/tmp/probe_state/blind_models.txt"
    if [ "${PASSIVE_ENABLED:-1}" = "1" ] && [ -f /app/passive_health.py ]; then
        echo "--- passive health scan (zero requests) ---"
        python3 /app/passive_health.py 2>&1 | tail -6 || echo "WARN: passive scan failed, falling back to blind file if exists"
    fi

    # ========== 阶段 2：只对“被动盲区”做主动探测 ==========
    local target_list="$MODEL_LIST"
    if [ "${ONLY_BLIND:-1}" = "1" ] && [ -s "$blind_file" ]; then
        target_list="$blind_file"
        echo "--- active probe: ONLY blind-zone ($(wc -l < "$blind_file" | tr -d ' ') models) ---"
    else
        echo "--- active probe: FULL sweep (ONLY_BLIND=${ONLY_BLIND:-1}) ---"
    fi

    local models=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        models+=("$line")
    done < "$target_list"

    local total=${#models[@]}
    echo "Total models to probe: $total"

    local idx=0 live=0 dead=0 unknown=0
    for model in "${models[@]}"; do
        idx=$((idx + 1))
        local verdict status
        verdict=$(probe_one "$model")
        status=$(write_health "$model" "$verdict")
        case "$status" in
            dead)    dead=$((dead+1));;
            suspect) live=$((live+1));;
            *)       unknown=$((unknown+1));;
        esac
        echo "  [$idx/$total] $model -> $verdict/$status"

        # ---- 限速：摊平突发，避免吃光上游并发额度导致用户侧 429 ----
        # 每个模型间 2~4s；每 25 个再长休 12~27s，更像真人节奏
        pause=$(( PROBE_PAUSE + RANDOM % (PROBE_PAUSE + 1) ))
        sleep "$pause"
        if [ "$idx" -lt "$total" ] && [ $((idx % BATCH_SIZE)) -eq 0 ]; then
            long=$(( BATCH_PAUSE + RANDOM % 16 ))
            echo "      ...batch rest ${long}s (rate limit)..."
            sleep "$long"
        fi
    done
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Cycle complete. alive=$live dead=$dead unknown=$unknown"
}

# 主循环：
# 静默时段判定：本地 00:00-08:00 不探活
#   - 其余时间：跑一轮 → sleep SLEEP 秒（+0~300s 随机抖动）
#   - 支持手动触发：docker exec prober touch /tmp/probe_now
#   - 支持一次性：  docker exec prober /app/probe.sh --once

# 静默时段判定：本地时间(UTC+8) 00:00-08:00 = UTC 16:00-23:59
# （容器无 tzdata，直接用 UTC 小时判断；中国无夏令时，恒为 UTC+8）
in_quiet_hours() {
    local h
    h=$(date -u +%H)
    h=$((10#$h))
    [ "$h" -ge 16 ]
}

# 可中断睡眠：每 20s 检查一次触发哨兵。返回 1 = 被手动触发
sleep_interruptible() {
    local secs="$1" elapsed=0
    while [ "$elapsed" -lt "$secs" ]; do
        if [ -f "$TRIGGER_FILE" ]; then
            rm -f "$TRIGGER_FILE"
            return 1
        fi
        sleep 20
        elapsed=$((elapsed + 20))
    done
    return 0
}

# --once：立即跑一整轮后退出（手动探活，不进后台循环）
if [ "${1:-}" = "--once" ]; then
    main
    exit 0
fi

while true; do
    if in_quiet_hours; then
        echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Quiet hours (local 00:00-08:00, UTC $(date -u +%H):xx) - skip probing; re-check in 600s..."
        if sleep_interruptible 600; then continue; fi
        echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Manual trigger during quiet hours - probing anyway."
    fi

    main || echo "WARN: cycle error, retrying next round"

    local_jitter=$((RANDOM % 900))
    local_sleep=$((SLEEP + local_jitter))
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Sleeping ${local_sleep}s (base ${SLEEP} + ${local_jitter}s jitter) before next cycle..."
    sleep_interruptible "$local_sleep" || continue
done
