#!/usr/bin/env python3
"""
被动健康检测：从 new-api 日志判定模型存活，零额外请求。

设计要点（用户明确要求）：
  1. 429 / 限额 / quota_exceeded 一律【不算死模型】—— 那是额度踩线，不是模型坏了
  2. 成功调用的 consume log 是最可靠的 LIVE 证据
  3. 只有「明确硬错误」且「最近无成功」才标 dead，且需累计若干次防抖

健康表 key 规则: health:<model_name.lower()>  (斜杠保留，如 health:deepseek-ai/deepseek-v4.1-flash)

输出: 把判定结果 PUT 到 sidecar 健康表
"""
import re
import os
import sys
import time
import json
import subprocess
import urllib.request
import urllib.error
import urllib.parse
from collections import defaultdict, Counter

GATEWAY = os.environ.get("GATEWAY_URL", "http://openresty:3000")
ADMIN_TOKEN = os.environ.get("ADMIN_TOKEN", "health-admin-token")
LOG_LINES = int(os.environ.get("LOG_LINES", "12000"))
WINDOW = int(os.environ.get("LIVE_WINDOW", os.environ.get("WINDOW", "86400")))  # 判定窗口 24h
DEAD_STREAK = int(os.environ.get("DEAD_STREAK", "2"))       # 硬错误累计几次才判死
DRY_RUN = os.environ.get("DRY_RUN", "") == "1"
STATE_FILE = os.environ.get("STATE_FILE", "/tmp/probe_state/consecutive_hard_fail.json")
# 跨轮成功记忆：防止日志窗口滚动把「活过」的事实遗忘
LAST_OK_FILE = os.environ.get("LAST_OK_FILE", "/tmp/probe_state/last_ok.json")
# 跨轮「死过」记忆：死模型没人调用 → 不进日志 → 永不续期 → sidecar TTL 一过就复活。
# 必须像 last_ok 一样自己记着，每轮续期，否则死模型会周期性重新可见。
LAST_DEAD_FILE = os.environ.get("LAST_DEAD_FILE", "/tmp/probe_state/last_dead.json")
# 死模型记忆多久内持续保持 DEAD（默认 30 天；fatal 类永久死）
DEAD_GRACE = int(os.environ.get("DEAD_GRACE", "2592000"))
# 记着它活过多久都不算盲区（默认 3 天）
BLIND_GRACE = int(os.environ.get("BLIND_GRACE", "259200"))
# new-api 日志打印所用时区相对容器本地时区(UTC)的偏移秒数。
# new-api 按 UTC+8 打印，容器是 UTC，故默认 8*3600。
# 若两者时区统一，设为 0 即可。
LOG_TZ_OFFSET = int(os.environ.get("LOG_TZ_OFFSET", "28800"))
# sidecar 健康表判定新鲜度：比这更新就不必再主动探测
HEALTH_MAX_AGE = int(os.environ.get("HEALTH_MAX_AGE", "86400"))

# ---- 错误分类 ----
# HARD: 模型/渠道本身不可用 → 可判死
HARD_CODES = {"400", "401", "403", "404", "410", "500", "502", "503", "504", "522", "524"}
# SOFT: 限流/额度/并发类 → 【绝不判死】
SOFT_CODES = {"429", "509"}

# 429 / 限额 / 并发类关键词：模型没坏，是额度或并发踩线
# 上游明确说「没有这个模型」/「渠道不支持」：确定性失败，永远不可能成功
# 例：unknown provider for model X / Invalid model: X / model_not_found
HARD_MODEL_ERRORS = [
    "unknown provider", "invalid model", "model_not_found", "not found",
    "no such model", "unsupported model", "model does not exist",
    "does not exist", "无权访问", "no available channel",
    # 中文/兼容写法（实测遇到）
    "模型未找到", "未找到模型", "模型不存在", "不支持的模型",
    "invalid token", "无效的 token", "unauthorized", "forbidden",
]

SOFT_KEYWORDS = [
    "429", "rate limit", "rate_limit", "rate-limit", "too many requests",
    "quota", "insufficient_quota", "限额", "限流", "限率", "额度", "余额不足",
    "concurrent", "并发", "at most", "requests per", "rpm", "tpm",
    "no_available_channel", "超出", "insufficient balance",
    # 上游有反测活机制：普通对话也可能命中关键词被拦，这不是模型坏了
    "反测活", "测活探针", "probe",
    # 临时性上游故障，不算模型死
    "temporarily unavailable", "try again", "please retry", "稍后重试",
    "bad gateway", "service unavailable", "upstream",
]

NOISE_TOKENS = {
    "requests", "request", "name", "status", "code", "limit", "reached",
    "the", "same", "user", "can", "run", "model", "channel", "token",
    "content", "userid", "channelid", "modelname", "tokemname",
}


def run_docker_logs(n):
    try:
        r = subprocess.run(
            ["docker", "logs", "new-api", "--tail", str(n)],
            capture_output=True, text=True, timeout=180,
        )
        return r.stdout.split("\n")
    except Exception as e:
        print(f"[passive] docker logs 失败: {e}", file=sys.stderr)
        return []


GIN_RE = re.compile(
    r"\[GIN\].*\|\s*relay\s*\|\s*([^|]+?)\s*\|\s*(\d{3})\s*\|"
)
# 权威数据源 1：成功计费行（含 model_name）
CONSUME_RE = re.compile(r'record consume log: userId=\d+.*?"model_name":"([^"]+)"')
# 权威数据源 2：错误行（含 modelName + status_code + 错误正文）
ERR_RE = re.compile(
    r'record error log: userId=(\d+), channelId=(\d+), modelName=([^,]+), '
    r'tokenName=([^,]+?), content=(.*)$'
)
# 错误上下文里的 model 线索
MODEL_CTX_RE = re.compile(r"model[=: ]+([a-zA-Z0-9._\-/:]+)")
NOW_RE = re.compile(r"^\[(?:INFO|WARN|ERROR|GIN)\]\s+(\d{4}/\d{2}/\d{2} - \d{2}:\d{2}:\d{2})")


def parse_ts(s):
    """解析 new-api 日志时间戳。

    坑：new-api 日志按 UTC+8 打印（20:35），而 prober 容器本地时区是 UTC（12:35）。
    time.mktime 会按「本地时区」解释这串数字，于是解析结果比真实时间超前 8 小时。

    后果是致命的：未来时间戳让 `now - last_ok[m]` 变成负数，
    永远满足 `<= BLIND_GRACE` → 这些模型永久被当成「我记得它活过」
    → 永不进盲区、永不被重探、永不判死 → 坏模型一直挂在列表里。
    （实测 46 条 last_ok 里有 36 条是未来时间戳。）

    所以这里必须减掉偏移，把日志时间归一到 UTC epoch。
    """
    try:
        ts = int(time.mktime(time.strptime(s, "%Y/%m/%d - %H:%M:%S")))
    except Exception:
        return 0
    return ts - LOG_TZ_OFFSET


def is_soft(code, content):
    """判断错误是否属于 429/限额/并发/反测活类（不算模型坏）"""
    if code in SOFT_CODES:
        return True
    low = (content or "").lower()
    for kw in SOFT_KEYWORDS:
        if kw in low:
            return True
    return False


def is_hard_model_error(content):
    """确定性失败：上游明确说「没这个模型」，永远不可能成功 → 可直接判死。

    实测发现 17 个可见模型属此类（`unknown provider for model X` /
    `Invalid model: X`），它们是被 new-api 渠道注册了名字但上游实际不支持的
    僵尸模型 —— 用户点一次失败一次，必须隐藏。
    """
    low = (content or "").lower()
    for kw in HARD_MODEL_ERRORS:
        if kw in low:
            return True
    return False


def clean_model(m):
    """清洗模型名，过滤噪音 token"""
    if not m:
        return None
    m = m.strip().lower()
    if not m or m in NOISE_TOKENS or len(m) < 2:
        return None
    if m.isdigit():
        return None
    if " " in m or "=" in m or '"' in m:
        return None
    return m


def extract(lines):
    """
    数据源优先级：
      1. record consume log  → 成功，LIVE 证据
      2. record error log    → 【权威】含 modelName + status_code + 正文
      3. GIN relay 非200     → 兜底，从上下文凑 model
    """
    stat = defaultdict(lambda: {"ok": [], "hard": [], "soft": [], "fatal": []})
    n = len(lines)
    last_ts = int(time.time())

    for i, line in enumerate(lines):
        if not line.strip():
            continue
        tm = NOW_RE.match(line)
        if tm:
            last_ts = parse_ts(tm.group(1))
        ts = last_ts

        # ---- 1. 成功：consume log ----
        mc = CONSUME_RE.search(line)
        if mc:
            mdl = clean_model(mc.group(1))
            if mdl:
                stat[mdl]["ok"].append(ts)
            continue

        # ---- 2. 权威错误行 ----
        me = ERR_RE.search(line)
        if me:
            mdl = clean_model(me.group(3))
            content = me.group(5)
            cm = re.search(r"status_code=(\d{3})", content)
            code = cm.group(1) if cm else ""
            if mdl:
                if is_soft(code, content):
                    stat[mdl]["soft"].append(ts)
                elif is_hard_model_error(content) or code in HARD_CODES:
                    # 确定性错误（没这个模型）或 HTTP 硬错误
                    if is_hard_model_error(content):
                        stat[mdl]["fatal"].append(ts)
                    else:
                        stat[mdl]["hard"].append(ts)
            continue

        # ---- 3. 兜底：GIN 非200 ----
        g = GIN_RE.search(line)
        if g and g.group(2) != "200":
            code = g.group(2)
            mdl = None
            for j in range(max(0, i - 6), min(n, i + 3)):
                mm = MODEL_CTX_RE.search(lines[j])
                if mm:
                    cand = clean_model(mm.group(1))
                    if cand:
                        mdl = cand
                        break
            if not mdl:
                continue
            ctx = "\n".join(lines[max(0, i - 6): min(n, i + 3)])
            if is_soft(code, ctx):
                stat[mdl]["soft"].append(ts)
            elif code in HARD_CODES:
                stat[mdl]["hard"].append(ts)

    return stat


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def load_last_ok():
    """跨轮记忆：每个模型最后一次成功调用的时间戳。

    为什么需要：docker logs --tail N 覆盖的时间跨度随日志密度波动，
    实测 12000 行只覆盖约 15h —— 老于 15h 的成功记录会被挤出窗口，
    模型被误判成「盲区」→ 每轮重探 77 个（用户又会 429）。
    持久化后：只要记得它活过，就不再当它未知。
    """
    try:
        with open(LAST_OK_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def load_last_dead():
    """跨轮记忆：{model: {"ts": 最后判死时间, "fatal": bool}}

    与 last_ok 对称的问题：死模型没人调用 → 不再出现在日志里 →
    extract() 看不到它 → put_health 永远不会被调用 → sidecar 里那条
    DEAD 记录 TTL/新鲜度一过就消失 → 模型重新可见（DEAD 数会逐轮流失，
    实测 123→80→67→36，盲区同步涨到 74）。

    记下来之后每轮续期，死模型就不会周期性复活。
    fatal（上游明确说没这个模型）记成永久死，不受 DEAD_GRACE 限制。
    """
    try:
        with open(LAST_DEAD_FILE) as f:
            data = json.load(f)
        # 兼容旧格式 {model: ts}
        out = {}
        for k, v in data.items():
            out[k] = v if isinstance(v, dict) else {"ts": v, "fatal": False}
        return out
    except Exception:
        return {}


def save_last_dead(d):
    try:
        os.makedirs(os.path.dirname(LAST_DEAD_FILE), exist_ok=True)
        with open(LAST_DEAD_FILE, "w") as f:
            json.dump(d, f)
    except Exception as e:
        print(f"[passive] last_dead 保存失败: {e}", file=sys.stderr)


def save_last_ok(d):
    try:
        os.makedirs(os.path.dirname(LAST_OK_FILE), exist_ok=True)
        with open(LAST_OK_FILE, "w") as f:
            json.dump(d, f)
    except Exception as e:
        print(f"[passive] last_ok 保存失败: {e}", file=sys.stderr)


def fetch_health_ts():
    """拉取 sidecar 健康表，返回 {model_lower: last_probe_ts}。

    用于排除「sidecar 里已有新鲜判定」的模型 —— 不必再主动探测。
    """
    url = f"{GATEWAY}/__modelnorm/health/list"
    req = urllib.request.Request(url, method="GET")
    req.add_header("Authorization", f"Bearer {ADMIN_TOKEN}")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.loads(r.read().decode(errors="replace"))
        out = {}
        for e in data.get("entries", []):
            key = e.get("key", "").replace("health:", "")
            try:
                v = json.loads(e.get("val", "{}"))
            except Exception:
                continue
            st = (v.get("status") or "").lower()
            # 只有明确结论（dead/live）才算「不必再探」。
            # suspect/unknown 是没有结论的状态，必须继续探 —— 否则这些模型
            # 会被永久排除在盲区之外，永远不被主动探测，也就永远不能定性。
            if st in ("dead", "live"):
                out[key] = v.get("last_probe_ts", 0)
        return out
    except Exception as e:
        print(f"[passive] 健康表拉取失败（盲区会偏大）: {e}", file=sys.stderr)
        return {}


def save_state(d):
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w") as f:
            json.dump(d, f)
    except Exception as e:
        print(f"[passive] state 保存失败: {e}", file=sys.stderr)


def put_health(model, status):
    """PUT 到 sidecar 健康表。sidecar 期望 JSON body（不是 query string！）"""
    url = f"{GATEWAY}/__modelnorm/health?model={urllib.parse.quote(model)}"
    # last_probe_ts 必须写！sidecar 读取时会校验新鲜度（默认 15300s），
    # 缺这个字段的判定会在几小时后被当作过期丢弃 → 死模型重新可见。
    payload = json.dumps({
        "model": model,
        "status": status.lower(),
        "last_probe_ts": int(time.time()),
    }).encode()
    req = urllib.request.Request(url, data=payload, method="PUT")
    req.add_header("Authorization", f"Bearer {ADMIN_TOKEN}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            body = r.read().decode(errors="replace")
            return r.status == 200 and '"ok":true' in body
    except urllib.error.HTTPError as e:
        return False
    except Exception:
        return False


def main():
    now = int(time.time())
    lines = run_docker_logs(LOG_LINES)
    if not lines:
        print("[passive] 无日志", file=sys.stderr)
        return 0
    print(f"[passive] 扫描 {len(lines)} 行")

    stat = extract(lines)
    prev = load_state()

    # ---- 跨轮记忆 + sidecar 新鲜度，用于压缩盲区 ----
    last_ok = load_last_ok()
    last_dead = load_last_dead()
    now0 = int(time.time())
    health_ts = fetch_health_ts()
    fresh_cut = now0 - HEALTH_MAX_AGE   # 健康表里比这更新的判定，视为不需要再探

    # 更新 last_ok：本轮日志里观察到的成功，记下最新时间戳
    for mdl, s in stat.items():
        oks = [t for t in s["ok"] if t > 0]
        if oks:
            newest = max(oks)
            if newest > last_ok.get(mdl, 0):
                last_ok[mdl] = newest

    # ---- 死模型续期名单（先算集合，PUT 在判定循环之后统一执行） ----
    # 记忆里仍算死的模型：本轮日志没出现（没人调用），但判定不能丢。
    # 每轮重新 PUT 一次，把 sidecar 的 TTL/新鲜度续上，否则死模型会复活。
    to_renew = []
    for model, info in last_dead.items():
        is_fatal = bool(info.get("fatal"))
        age = now0 - int(info.get("ts", 0))
        if is_fatal or age <= DEAD_GRACE:
            to_renew.append(model)
    renewed = 0

    # ---- 盲区名单 ----
    # 三级过滤，避免「日志窗口遗忘」导致的虚假盲区：
    #   ① 本轮日志里出现过       → 非盲区（被动能判定）
    #   ② last_ok 记忆里仍新鲜   → 非盲区（记得它活过）
    #   ③ sidecar 健康表有新鲜判定 → 非盲区（已有结论，不必再探）
    blind = []
    try:
        mt_path = os.environ.get("MODEL_LIST", "/app/models.txt")
        full = []
        for m in open(mt_path, errors="replace").read().split("\n"):
            m = m.strip()
            if m and not m.startswith("#"):
                full.append(m.lower())
        for name in sorted(set(full)):
            if name in stat:
                continue                                   # ①
            if now0 - last_ok.get(name, 0) <= BLIND_GRACE:  # ②
                continue
            dead = last_dead.get(name)
            if dead:                                       # ②b 记得它死过
                age = now0 - int(dead.get("ts", 0))
                if dead.get("fatal") or age <= DEAD_GRACE:
                    continue
            ts = health_ts.get(name, 0)
            if ts and ts >= fresh_cut:                     # ③
                continue
            blind.append(name)
        os.makedirs("/tmp/probe_state", exist_ok=True)
        with open("/tmp/probe_state/blind_models.txt", "w") as f:
            f.write("\n".join(blind) + ("\n" if blind else ""))
        print(f"[passive] 盲区 {len(blind)} 个"
              f"（日志覆盖{len(stat)}/记忆活{len(last_ok)}/记忆死{len(last_dead)}/健康表{len(health_ts)}，"
              f"续期死模型{renewed}，"
              f"阈值 window={WINDOW}s grace={BLIND_GRACE}s dead_grace={DEAD_GRACE}s sidecar_fresh={HEALTH_MAX_AGE}s）"
              f" → /tmp/probe_state/blind_models.txt")
    except Exception as e:
        print(f"[passive] 盲区计算失败: {e}", file=sys.stderr)

    counts = Counter()
    rows = []
    for model, s in sorted(stat.items()):
        ok = [t for t in s["ok"] if now - t <= WINDOW]
        hard = [t for t in s["hard"] if now - t <= WINDOW]
        soft = [t for t in s["soft"] if now - t <= WINDOW]
        fatal = [t for t in s.get("fatal", []) if now - t <= WINDOW]

        # 日志窗口忘了成功的、但记忆里仍新鲜的 → 视为活（防止列表突然泄露）
        if not ok and now - last_ok.get(model, 0) <= BLIND_GRACE:
            ok = [last_ok[model]]

        # 确定性失败（上游明确说没这个模型）：一次就判死，不必等 DEAD_STREAK
        if ok:
            verdict = "LIVE"
            prev[model] = 0
            last_dead.pop(model, None)          # 活过 → 抹掉死记忆
        elif fatal:
            # 上游明确说没这个模型 → 直接判死，无需累计；且永久死
            verdict = "DEAD"
            prev[model] = DEAD_STREAK
            last_dead[model] = {"ts": now, "fatal": True}
        elif hard:
            streak = prev.get(model, 0) + len(hard)
            prev[model] = streak
            verdict = "DEAD" if streak >= DEAD_STREAK else None
            if verdict == "DEAD":
                last_dead[model] = {"ts": now, "fatal": False}
        elif soft:
            # 纯 429/限额 → 明确不动，不判死
            verdict = None
            prev[model] = 0
        else:
            verdict = None

        if verdict is None:
            counts["skip"] += 1
            continue

        counts[verdict] += 1
        if soft and verdict == "LIVE":
            counts["had_soft"] += 1

        put = True
        if not DRY_RUN:
            put = put_health(model, "LIVE" if verdict == "LIVE" else "DEAD")
        rows.append((model, verdict, len(ok), len(hard), len(soft), put))

    # ---- 死模型续期：重新 PUT，续上 sidecar 的 TTL/新鲜度 ----
    for model in sorted(to_renew):
        if model in stat:
            continue                                   # 本轮已判定过，跳过
        if DRY_RUN:
            renewed += 1
            continue
        if put_health(model, "DEAD"):
            renewed += 1
            counts["DEAD"] += 1
        else:
            print(f"  [续期失败] {model}", file=sys.stderr)

    for model, v, o, h, s_, put in rows:
        warn = "" if put else "  [PUT失败/未登记]"
        note = "  <-含429证据仍判活(不误杀)" if (s_ and v == "LIVE") else ""
        print(f"  {model:42s} {v:4s} ok={o:<3d} hard={h:<3d} soft={s_:<3d}{warn}{note}")

    save_state(prev)
    save_last_ok(last_ok)
    save_last_dead(last_dead)
    print(f"\n[passive] LIVE={counts['LIVE']} DEAD={counts['DEAD']} "
          f"(含429证据仍判活={counts['had_soft']}) 观察中={counts['skip']} 盲区={len(blind)}")
    print("[passive] 规则: 纯429/限额一律不判死 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
