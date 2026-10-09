# modelnorm-sidecar

**NewAPI 出口层 sidecar：模型列表归一化 + 自动探活 + 死模型过滤。**

本仓库只包含 sidecar 自身（OpenResty 配置 + prober 容器 + 工具链），**不含 new-api 本体**。new-api 是第三方开源项目（[QuantumNous/new-api](https://github.com/QuantumNous/new-api)），作为外部依赖由其官方 compose 部署，本 sidecar 挂到它的 docker 网络上做出口层。

## 解决什么问题

NewAPI 聚合多个上游供应商后，`/v1/models` 会返回大量同名变体（大小写 / 前缀 / `:free` 后缀 / 日期戳 / thinking 档位），agent 的模型 picker 里挤满重复条目；渠道挂了列表照常显示，选到死模型才报 `No available channel`。

本 sidecar 在 new-api 出口前架一层 OpenResty，做三件事：

1. **归一化**：把同名变体折叠成一个名字（agent 零改动，base_url 指向 sidecar 即可）
2. **合成名**：为没有干净名的上游模型造一个（如 `laguna-xs-2.1:free` → `laguna-xs-2.1`），请求时翻译回真名
3. **探活过滤**：死的模型从 `/v1/models` 列表里隐藏。判定以**读 new-api 日志为主（零请求）**，只对日志覆盖不到的少数模型做低频主动探测（fail-open：超时≠死，防误杀）

## 依托关系

```
agent (base_url = http://<host>:3000)        ← 零改动
          │
          ▼
┌─ 本仓库：sidecar 层 ──────────────────────────┐
│  openresty 容器 :3000                        │
│   GET /v1/models → 折叠 + 合成 + 死模型过滤   │
│   POST /v1/*     → 合成名翻译 → 透传 (SSE)    │
│   /__modelnorm/health → 健康表管理端点        │
├──────────────────────────────────────────────┤
│  prober 容器（每 4 小时一轮）                  │
│   ├ 阶段1 被动：读 new-api 日志，零请求        │
│   │         ~169/182 模型由此判定              │
│   └ 阶段2 主动：只测日志盲区 ~13 个            │
│        （限速 2~4s/个，约 40 秒跑完）          │
│   → PUT 健康表 → dead 自动隐藏                 │
└──────────────────┬───────────────────────────┘
                   │ 同一 docker 网络
                   ▼
        ┌─ 第三方依赖（不在本仓库）─────────────┐
        │  new-api 容器 :3000  (QuantumNous/new-api) │
        │  + postgres + redis                       │
        └───────────────────────────────────────────┘
```

new-api / postgres / redis 由其[官方 compose](https://github.com/QuantumNous/new-api) 部署，本仓库的 `compose.example.yml` 只编 sidecar 两个容器，通过 `external: true` 网络挂到已有 new-api 部署上。

## 文件

| 文件 | 作用 |
|---|---|
| `compose.example.yml` | sidecar 编排（仅 openresty + prober，挂到已有 new-api 网络） |
| `openresty/Dockerfile` | OpenResty alpine 镜像 |
| `openresty/default.conf` | 全部归一化 + 健康表逻辑（http 级指令 + Lua） |
| `prober/Dockerfile` | 探活容器（alpine + curl + bash） |
| `prober/probe.sh` | 主循环：阶段1 调被动检测，阶段2 只测盲区（含静默时段 / 手动触发哨兵 / `--once`） |
| `prober/passive_health.py` | **被动检测器**：解析 new-api 日志判定存活，零请求；429 不当死模型 |
| `probe-now.sh` | 手动触发探活（立刻触发一轮 / `--once` 前台跑 / `--status` 看健康表） |
| `deploy-prober.sh` | 带自动回滚的部署脚本（6 步校验，失败自动还原旧镜像） |
| `prober/models.txt` | 探活名单（必须覆盖上游全量列表，漏掉的名字永远不会隐藏） |
| `probe-now.sh` | 手动触发探活（立刻触发一轮 / `--once` 前台跑 / `--status` 看健康表） |
| `verify.sh` | 回归自检（fail-closed，12 项） |
| `verify_health.sh` | 健康表专项自检 |
| `tools/normgen.py` | 合成表重生成脚本 |
| `tools/mn_test.lua` | LuaJIT 单测（canon 函数） |
| `tools/mn_health_test.lua` | 健康表逻辑单测 |
| `tools/README.md` | 工具链说明 |
| `.env.example` | PROBER_TOKEN / ADMIN_TOKEN 占位 |

## 快速开始

```bash
# 1. 先部署 new-api（官方 compose），记下 docker 网络名
docker network ls   # 通常是 <项目名>_default，如 newapi_default

# 2. 克隆本仓库，配 sidecar
git clone <this-repo> modelnorm-sidecar && cd modelnorm-sidecar
cp .env.example .env   # 填 PROBER_TOKEN=sk-...（new-api 的 token）

# 3. 把 compose.example.yml 里的网络名改成第 1 步查到的实际名（默认 newapi_default）

# 4. 构建并启动 sidecar
docker compose -f compose.example.yml build
docker compose -f compose.example.yml up -d

# 5. 验证
bash verify.sh         # 12/12 PASS 为部署完成
```

agent 的 `base_url` 从 `http://<new-api>:3000` 改成 `http://<host>:3000`（指向 sidecar）即可，其余零改动。

## 探活判定（fail-open 核心）

| 单轮结果 | 健康表 | /v1/models |
|---|---|---|
| 有 `"choices"` | suspect | 显示 |
| 有 `"error"` 第 1 次 | suspect | 显示 |
| 有 `"error"` 连续第 2 次 | **dead** | **隐藏** |
| curl 超时/网络错误 | unknown | 显示（超时≠死） |
| TTL 8.5 小时过期（30600s） | 条目消失 | 重新显示 |

**TTL 必须大于探针间隔（红线）**：部署值为 TTL=30600s(8.5h) vs 间隔=14400s(4h)+≤900s 抖动。
曾因 TTL=2700s(45min) < 间隔 3600s，导致每小时有 15+ 分钟健康表全空 → 死模型周期性重现（列表一夜回到解放前）。

## 探活架构：被动优先（2026-10-07 重构）

**核心思路：能不看就不主动问。** new-api 每笔调用都打了日志，直接读日志判定即可，不必拿自己的额度和并发去试。

### 阶段 1：被动检测（零请求）

`prober/passive_health.py` 解析 `docker logs new-api`，两类权威日志：

```
# 成功 → 最强 LIVE 证据
record consume log: userId=1, params={...,"model_name":"hy4-preview",...}

# 失败 → 【权威】直接含 modelName + status_code + 错误正文
record error log: userId=1, channelId=7, modelName=glm-5.2, tokenName=...,
  content=status_code=429, Concurrent request limit reached: the same user can run at most 3 model
```

覆盖率：**182 个模型中 ~169 个（93%）** 能被日志判定，剩下 ~13 个（无人调用过的冷门模型）才需要主动兜底。

### 坑：429 不是死模型（重要）

上面的样例就是典型：**用户并发上限被打满**（同一用户最多 3 并发），模型本身活得好好的。
若据此标 dead，等于自己把自己的模型判死。判定规则：

| 证据 | 判定 |
|---|---|
| 窗口内有成功调用 | **LIVE**（哪怕同时也有失败） |
| 上游明确说「没这个模型」`unknown provider` / `Invalid model` / `模型未找到` / `Invalid token` | **DEAD**（确定性失败，一次即判） |
| 只有硬错误（400/401/403/404/410/500/502/503/504/522/524）且无成功 | 累计 ≥2 次才 **DEAD**（防抖） |
| 只有 429 / 限额 / quota / `Concurrent request limit` / `temporarily unavailable` / 上游「反测活拦截」 | **不动，绝不判死** |
| 超时 | UNKNOWN → 显示（fail-open） |

> **别忘了全 lowercase 比对**：曾因 Python 端写大写 `DEAD`、Lua 端严格比对小写 `"dead"`，
> 导致 **72 个死模型一个都没被过滤**（2026-10-08）。现在两端都做了小写归一化。

> **反测活**：部分上游会拦截 `hi`/`你好` 这类短消息
> （返回「短消息命中测活探针关键词」）。这**不代表模型坏了**，
> 已归入 soft 不判死 —— 顺带说明：**不要把探活提示词写得像探针**。

### 阶段 1.5：死模型续期（防复活）

**为什么需要**：这是个反直觉的坑。死模型被过滤掉之后 → 没人调用它 →
它不再出现在 new-api 日志里 → `extract()` 看不到它 → `put_health` 永远不会被调用
→ sidecar 里那条 DEAD 记录 8.5h TTL 一过就消失 → **模型重新可见**。

于是 DEAD 数会逐轮流失，盲区同步暴涨（实测 `123 → 80 → 67 → 36`，盲区 `2 → 74`），
表现为「死模型周期性复活、每轮盲区重探一大堆、用户又 429」。

**解法**：`last_dead.json` 持久化死模型记忆，每轮对其中**未在本轮日志出现**的模型
重新 PUT 一次 DEAD，续上 sidecar 的 TTL。同时把它们排除出盲区，避免每轮重探。

- `fatal`（上游明确说没这个模型：`unknown provider` / `Invalid model` / `模型未找到`）→ **永久死**，不受 `DEAD_GRACE` 限制
- 普通硬错误判死 → `DEAD_GRACE`（默认 30 天）内保持死，超期后给它机会复活
- 一旦观测到成功调用 → 立刻从 `last_dead` 抹掉

### 阶段 2：主动兜底（只对盲区）

被动扫完会生成 `/tmp/passive_state/blind_models.txt`，`probe.sh` 只读这个文件去探测（默认 `ONLY_BLIND=1`）。

- **不是 ping**：7 条自然短句随机选，`max_tokens=8`
  ```
  用一句话概括今天天气很好。/ 翻译：你好世界。/ 请回复：好。/ 把数字 1 翻译成中文。…
  ```
- **限速**：每个模型间隔 `PROBE_PAUSE=2`(2~4s)，每 25 个长休 `BATCH_PAUSE=12`(12~27s)
  → 一轮 13 个约 40 秒，**速率 ~0.3 req/s**，不会吃满上游并发导致用户侧 429
- **静默时段**：本地 00:00–08:00 不探活（容器 alpine 无 tzdata，`TZ` 无效，脚本内按 `date -u +%H >= 16` 判定）

### 坑：日志窗口会遗忘，盲区会虚高（2026-10-08 修复）

`docker logs --tail 12000` 的**覆盖时长随日志密度浮动**，实测只覆盖约 **15 小时**。
一旦某个模型的调用记录滚出窗口，它就被当成「没人用过」→ 进盲区 → 被拉去主动探测。
实测盲区一度从 **13 虚高到 77**，等于退化回旧方案，用户又会 429。

修复：**三级过滤 + 跨轮记忆**，给模型记着「它活过」。

```
① 本轮日志里出现过          → 非盲区（被动能判定）
② last_ok 记忆仍新鲜        → 非盲区（记得它活过，默认记 3 天 BLIND_GRACE）
③ sidecar 健康表有新鲜判定  → 非盲区（已有结论，HEALTH_MAX_AGE 默认 24h）
```

三级都没命中的才进盲区。修复后 **盲区 77 → 2**。

记忆文件 `/tmp/passive_state/last_ok.json`，容器重建会丢 —— 但第 ③ 级
（sidecar 健康表）兜住了绝大部分，丢失后最多一轮就能自愈。

### 效果

| 指标 | 原始 | 被动化后 | + 盲区修复 |
|---|---|---|---|
| 主动请求/轮 | 182 | 13 | **2** |
| 一轮耗时 | 6–10 分钟 | ~40 秒 | **~7 秒** |
| 每天请求量 | ~1092 | ~78 | **~12（↓99%）** |

### 手动触发

```bash
./probe-now.sh            # 立刻触发一轮（不打断后台循环）
./probe-now.sh --once     # 前台跑完一轮看完整输出
./probe-now.sh --status   # 健康表统计（dead/suspect/unknown）

docker exec prober touch /tmp/probe_now      # 等价哨兵触发
```

### 部署（带自动回滚）

改了 prober 后**必须重建容器**（代码是 COPY 进镜像的），用现成脚本：

```bash
bash deploy-prober.sh
```

6 步：前置检查 openresty 健康 → 备份镜像 → 备份 probe_state → 语法校验 → 构建重建 → 恢复 state + 断言新代码生效 + 断言链路仍通。
任一步失败 `trap` 自动用备份镜像回滚，**prober 挂了不影响 openresty/new-api 链路**。

> 注意：改 `default.conf` 不用重建，`docker cp` + `openresty -s reload` 即可（热重载会清空 shared_dict，死模型短暂重现，下轮恢复）。

### 一次性清理僵尸模型

有些模型 new-api 渠道里注册了名字、上游实际不支持（`unknown provider` / `Invalid model`），
或上游长期故障返回空错误。逐个实测后可以直接标死，立即从列表消失：

```bash
for m in glm-5.1 kimi-k3 gemini-3.6-flash SenseAudio-S1; do
  curl -s -X PUT "http://localhost:3000/__modelnorm/health?model=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$m")" \
    -H "Authorization: Bearer health-admin-token" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$m\",\"status\":\"dead\"}"
done
```

**注意 status 必须是小写 `dead`**（大写不会被过滤逻辑匹配）。

批量验证 "放出来的模型是否真能用"：

```bash
TOKEN=sk-your-token
curl -s "http://localhost:3000/v1/models" -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import sys,json;print('\n'.join(m['id'] for m in json.load(sys.stdin)['data']))" \
  | while read m; do
      code=$(curl -s -o /tmp/r.json -w '%{http_code}' -X POST http://localhost:3000/v1/chat/completions \
        -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"把数字 1 翻译成中文\"}],\"max_tokens\":8}")
      grep -q '"choices"' /tmp/r.json && echo "OK   $m" || echo "FAIL $m ($code)"
    done
```

提示词别用 `hi` —— 部分上游有**反测活**，会拦截短消息（不代表模型坏）。

## 设计红线

1. 规则只从名字形态生成，**不依赖供应商/渠道配置**（new-api 后端变动不影响 sidecar）
2. 折叠/改名不改变路由：被隐藏的名字仍可按原名调用
3. 合成名请求翻译：只翻译上游不存在的合成名，fail-open（翻译失败原样透传）
4. fail-open 探活：超时≠死，连续 2 轮明确报错才隐藏（防误杀）
5. 改 Lua 规则必须真 LuaJIT 实测（Python re 模拟无效），canon 函数禁 while/组量词
6. 事故时先回滚恢复服务、再查根因

## 踩坑索引

完整踩坑记录（Lua 死循环事故、探活系统 H1–H9、TTL 耦合事故、防封调优、被动化重构）见笔记库：`hermes-notes/AI_notes/2026-09-20-NewAPI模型列表归一化sidecar.md`、`concepts/2026-09-21-newapi-路由机制与模型名映射边界.md`、`AI_notes/2026-09-28-NewAPI探活调优与健康表TTL坑.md`、`AI_notes/2026-10-07-探活被动化重构与429不当死模型.md`。

高频坑速查：

- `default.conf` 只能写 http 级指令（写 `worker_processes`/`events` → 容器崩溃循环）
- openresty 真正加载 `/usr/local/openresty/nginx/conf/nginx.conf`（不是 `/etc/nginx/nginx.conf`）
- `init_by_lua` 阶段 `cjson` 全局未注入 → 显式 `pcall(function() cjson = require "cjson" end)`
- 该 OpenResty 版本没有 `dict:keys()`，用 `dict:get_keys(0)`
- `error.log` 是 `/dev/stderr` 符号链接：`docker exec tail` 它会永久挂起，用 `docker logs`
- Dockerfile 没有 CMD → 容器秒退循环
- prober 不监听端口：healthcheck 用 `pgrep -f probe.sh`
- healthcheck 别用 `/v1/models`（要鉴权），用 `/api/status`
- 合成名撞上游新真名 → verify.sh 会抓出，从 `MN_SYNTH_REWRITE` 删该条（真名优先）
- 健康表 TTL 必须 > 探针间隔（TTL ≥ 2×(间隔+抖动)），否则每轮之间条目过期 → 死模型周期性重现
- `models.txt` 必须覆盖 `:3001` 直连全量列表；新加的名字需 2 轮才有判定，期间先显示为 suspect
- 重建 prober 容器会清掉 `/tmp/probe_state` → 用 `deploy-prober.sh`（自动备份恢复）
- **429 / `Concurrent request limit` 一律不判死** —— 那是并发或额度踩线，不是模型坏了
- **PUT 健康表必须用 JSON body**，不是 query string；用错会静默丢弃（曾致 84 个判定全部丢失）
- prober 依赖 `docker.sock`（只读挂载）来 `docker logs new-api`，缺了被动检测会失效
- **`--tail N` 的日志覆盖时长会随密度浮动**（实测 12000 行只有 ~15h）。判定窗口大于实际覆盖时会「遗忘」老结论 → 盲区虚高 → 退化回全量探测。必须配 `BLIND_GRACE` / `HEALTH_MAX_AGE` 做记忆兜底
- **健康表 status 是全小写语义**：`"DEAD"` 不会被 `h.status == "dead"` 匹配到，写入端务必 `.lower()`
- **Lua 里先判 nil 再取字段**：`if h and h.status:lower() == "dead"` 的写法在 `h == nil` 时会
  `attempt to index local 'h'` 直接 500。必须写成 `if h then local st = h.status ... end`
- **死模型必须主动续期**：死模型没人调用 → 不进日志 → 永不被重新 PUT → sidecar TTL 一过
  标记消失 → 周期性复活（实测 DEAD 123→80→67→36，盲区涨到 74）。见「死模型复活」一节
- **状态目录必须和被备份的目录一致**：passive 曾写到 `/tmp/passive_state`，
  而 deploy 只备份 `/tmp/probe_state` → 每次重建记忆全丢 → 盲区暴涨需多轮自愈
- **日志时区**：new-api 按 UTC+8 打印，容器是 UTC，`mktime` 会解析出**未来时间戳**，
  让所有 `now - ts` 比较静默失效。用 `LOG_TZ_OFFSET`（默认 28800）校正
- **标死要用真实 id，不是显示名**：`/v1/models` 显示的是 `MN_SYNTH_REWRITE` 改写的合成名
  （`claude-opus-4-5` → 真实 `claude-opus-4-5-20251101`）。过滤检查的是真实 id，
  按显示名标 dead 完全无效
- **「慢」≠「死」**：15s 超时的模型可能只是响应慢（实测 grok-4.6 在 60s 下正常）。
  判死前要用长超时复测，否则会误杀可用模型

## License

本 sidecar 配置与脚本部分：MIT。
new-api 本体遵循其自身 license（[QuantumNous/new-api](https://github.com/QuantumNous/new-api)），不包含在本仓库中。
