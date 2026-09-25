# modelnorm-sidecar

**NewAPI 出口层 sidecar：模型列表归一化 + 自动探活 + 死模型过滤。**

本仓库只包含 sidecar 自身（OpenResty 配置 + prober 容器 + 工具链），**不含 new-api 本体**。new-api 是第三方开源项目（[QuantumNous/new-api](https://github.com/QuantumNous/new-api)），作为外部依赖由其官方 compose 部署，本 sidecar 挂到它的 docker 网络上做出口层。

## 解决什么问题

NewAPI 聚合多个上游供应商后，`/v1/models` 会返回大量同名变体（大小写 / 前缀 / `:free` 后缀 / 日期戳 / thinking 档位），agent 的模型 picker 里挤满重复条目；渠道挂了列表照常显示，选到死模型才报 `No available channel`。

本 sidecar 在 new-api 出口前架一层 OpenResty，做三件事：

1. **归一化**：把同名变体折叠成一个名字（agent 零改动，base_url 指向 sidecar 即可）
2. **合成名**：为没有干净名的上游模型造一个（如 `laguna-xs-2.1:free` → `laguna-xs-2.1`），请求时翻译回真名
3. **探活过滤**：prober 容器每 15 分钟探活全量模型，连续 2 轮明确报错才标 dead 从列表隐藏（fail-open：超时≠死，防误杀）

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
│  prober 容器（每 15 分钟）                    │
│   114 模型各 1 个 max_tokens=1 探活           │
│   → PUT 健康表 → dead 自动隐藏                │
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
| `prober/probe.sh` | 探活主脚本（fail-open 判定） |
| `prober/models.txt` | 探活名单（按上游列表生成） |
| `verify.sh` | 回归自检（fail-closed，12 项） |
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
| TTL 45 分钟过期 | 条目消失 | 重新显示 |

## 设计红线

1. 规则只从名字形态生成，**不依赖供应商/渠道配置**（new-api 后端变动不影响 sidecar）
2. 折叠/改名不改变路由：被隐藏的名字仍可按原名调用
3. 合成名请求翻译：只翻译上游不存在的合成名，fail-open（翻译失败原样透传）
4. fail-open 探活：超时≠死，连续 2 轮明确报错才隐藏（防误杀）
5. 改 Lua 规则必须真 LuaJIT 实测（Python re 模拟无效），canon 函数禁 while/组量词
6. 事故时先回滚恢复服务、再查根因

## 踩坑索引

完整踩坑记录（Lua 死循环事故、探活系统 H1–H9）见笔记库：`hermes-notes/AI_notes/2026-09-20-NewAPI模型列表归一化sidecar.md` 与 `concepts/2026-09-21-newapi-路由机制与模型名映射边界.md`。

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

## License

本 sidecar 配置与脚本部分：MIT。
new-api 本体遵循其自身 license（[QuantumNous/new-api](https://github.com/QuantumNous/new-api)），不包含在本仓库中。
