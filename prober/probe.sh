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
#   SLEEP         轮次间隔秒数，默认 900（15 分钟）
#   ADMIN_TOKEN   默认 health-admin-token（需与 default.conf 一致）
#   TOKEN         new-api 鉴权 token（必填）

set -eu

GATEWAY_URL="${GATEWAY_URL:-http://openresty:3000}"
MODEL_LIST="${MODEL_LIST:-/app/models.txt}"
SLEEP="${SLEEP:-900}"
ADMIN_TOKEN="${ADMIN_TOKEN:-health-admin-token}"
TOKEN="${TOKEN:-}"
STATE_DIR="/tmp/probe_state"

[ -z "$TOKEN" ] && { echo "FATAL: TOKEN env is required (new-api bearer token)" >&2; exit 1; }
mkdir -p "$STATE_DIR"

die() { echo "FATAL: $*" >&2; exit 1; }

state_key() { echo "$STATE_DIR/$(echo "$1" | md5sum | cut -d' ' -f1)"; }

# 探活单个模型（超时 90s，上游链路慢是常态）
# 返回: LIVE|DEAD|UNKNOWN
probe_one() {
    local model="$1"
    local body rc=0
    body=$(curl -s -m 90 -X POST "${GATEWAY_URL}/v1/chat/completions" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}") || rc=$?
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
        LIVE)    status="suspect";;   # 活，但按原约定记 suspect（不过滤）
        DEAD)    [ "$prev" = "DEAD" ] && status="dead" || status="suspect";;
        UNKNOWN) status="unknown";;
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

    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Starting probe cycle (gateway=$GATEWAY_URL)"

    local models=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        models+=("$line")
    done < "$MODEL_LIST"

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
    done
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Cycle complete. alive=$live dead=$dead unknown=$unknown"
}

# 主循环：每轮探活后 sleep SLEEP 秒
while true; do
    main "$@" || echo "WARN: cycle error, retrying next round"
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Sleeping ${SLEEP}s before next cycle..."
    sleep "$SLEEP"
done
