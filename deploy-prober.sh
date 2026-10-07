#!/usr/bin/env bash
# deploy-prober.sh — 带自动回滚的 prober 部署脚本
#
# 核心保障：任何一步失败都自动还原旧镜像，保证 new-api/openresty（我的链路）不受影响
#   - 备份旧镜像 tag  → 失败时用旧 tag 重建
#   - 备份 probe_state → 新容器起来后拷回
#   - 全程健康检查 + 断言
#
# 用法: ./deploy-prober.sh
set -uo pipefail

cd "$(dirname "$0")" || exit 1

BACKUP_TAG=""
STATE_BAK="/tmp/probe_state_bak_$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/tmp/prober-deploy-$(date +%Y%m%d-%H%M%S).log"

rollback() {
    # 关闭 trap，防止回滚过程中再次触发自己递归
    trap - ERR
    echo ""
    echo "!!!!!!!!!! 部署失败，触发回滚 !!!!!!!!!!"
    echo "旧镜像 tag: ${BACKUP_TAG:-未创建}"
    if [ -z "${BACKUP_TAG:-}" ]; then
        echo "✗ 无备份镜像，无法自动回滚。手动跑：docker compose up -d prober"
        exit 1
    fi
    docker compose down prober >/dev/null 2>&1
    docker run -d --name prober \
        --network newapi_default \
        --restart always \
        -e GATEWAY_URL=http://openresty:3000 \
        -e MODEL_LIST=/app/models.txt \
        -e SLEEP=14400 \
        -e ADMIN_TOKEN=health-admin-token \
        -v "$(pwd)/prober/models.txt:/app/models.txt:ro" \
        "$BACKUP_TAG" >/dev/null 2>&1
    sleep 3
    if docker ps --filter name=prober --format '{{.Status}}' | grep -q Up; then
        echo "✓ 已用旧镜像回滚，prober 恢复运行"
    else
        echo "✗ 回滚失败！prober 未运行（不影响 openresty/new-api）"
    fi
    exit 1
}

trap rollback ERR

echo "=== prober 部署（带自动回滚）==="
echo "日志: $LOG_FILE"

# ---- 第 0 步：前置检查（确认当前链路健康）----
echo ""
echo "[0/6] 前置健康检查..."
curl -s -m 8 -o /dev/null -w "  openresty /api/status: HTTP %{http_code}\n" http://localhost:3000/api/status
[ "$(curl -s -m 8 -o /dev/null -w '%{http_code}' http://localhost:3000/api/status)" = "200" ] \
    || { echo "✗ openresty 不健康，中止"; exit 1; }
echo "  ✓ 链路正常，可以安全部署"

# ---- 第 1 步：备份旧镜像 ----
echo ""
echo "[1/6] 备份当前镜像..."
if docker images newapi-prober --format '{{.ID}}' | grep -q .; then
    OLD_IMAGE=$(docker images newapi-prober --format '{{.ID}}' | head -1)
    BACKUP_TAG="newapi-prober:rollback-$(date +%Y%m%d-%H%M%S)"
    docker tag "$OLD_IMAGE" "$BACKUP_TAG"
    echo "  ✓ 旧镜像已备份为 $BACKUP_TAG"
else
    echo "  ! 无旧镜像，跳过备份"
fi

# ---- 第 2 步：备份 probe_state ----
echo ""
echo "[2/6] 备份 probe_state..."
rm -rf "$STATE_BAK"
docker cp prober:/tmp/probe_state "$STATE_BAK" 2>/dev/null \
    && echo "  ✓ 备份 $(ls "$STATE_BAK" | wc -l | tr -d ' ') 个状态文件" \
    || echo "  ! 无状态可备份（容器可能已停）"

# ---- 第 3 步：语法/配置校验（失败就不往下走）----
echo ""
echo "[3/6] 校验脚本..."
bash -n prober/probe.sh || { echo "✗ probe.sh 语法错误"; exit 1; }
python3 -c "import ast; ast.parse(open('prober/passive_health.py').read())" || { echo "✗ passive_health.py 语法错误"; exit 1; }
docker compose config >/dev/null || { echo "✗ compose 配置错误"; exit 1; }
echo "  ✓ 全部通过"

# ---- 第 4 步：构建 + 重建 ----
echo ""
echo "[4/6] 构建并重建容器..."
docker compose up -d --build prober 2>&1 | tail -5

# ---- 第 5 步：等待健康 ----
echo ""
echo "[5/6] 等待容器健康..."
for i in $(seq 1 30); do
    ST=$(docker ps --filter name=prober --format '{{.Status}}' 2>/dev/null)
    if echo "$ST" | grep -q "healthy"; then
        echo "  ✓ $ST"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  ✗ 超时未健康: $ST"
        docker logs prober --tail 15 2>&1
        exit 1
    fi
    sleep 2
done

# ---- 第 6 步：恢复状态 + 断言新代码生效 ----
echo ""
echo "[6/6] 恢复 state 并断言新代码..."
[ -d "$STATE_BAK" ] && docker cp "$STATE_BAK/." prober:/tmp/probe_state 2>/dev/null \
    && echo "  ✓ 状态已恢复 $(docker exec prober ls /tmp/probe_state 2>/dev/null | wc -l | tr -d ' ') 个文件"

# 断言：新容器的 probe.sh 必须含 passive 代码
if docker exec prober grep -q "passive health scan" /app/probe.sh 2>/dev/null; then
    echo "  ✓ 新代码已生效（含 passive scan）"
else
    echo "  ✗ 新代码未生效！"
    exit 1
fi

# 断言：我的链路仍然通
sleep 2
if [ "$(curl -s -m 8 -o /dev/null -w '%{http_code}' http://localhost:3000/api/status)" = "200" ]; then
    echo "  ✓ openresty 链路正常（我没断联）"
else
    echo "  ✗ openresty 异常！"
    exit 1
fi

echo ""
echo "========== 部署成功 =========="
echo "回滚镜像保留: ${BACKUP_TAG:-未创建}"
echo "（确认无误后可自行删除：docker rmi ${BACKUP_TAG:-<无>}）"
echo ""
echo "查看日志: docker logs -f prober"
# 关闭 ERR trap，避免退出时 rollback 被误触发
trap - ERR
exit 0
