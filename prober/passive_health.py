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
STATE_FILE = "/tmp/passive_state/consecutive_hard_fail.json"

# ---- 错误分类 ----
# HARD: 模型/渠道本身不可用 → 可判死
HARD_CODES = {"400", "401", "403", "404", "410", "500", "502", "503", "504", "522", "524"}
# SOFT: 限流/额度/并发类 → 【绝不判死】
SOFT_CODES = {"429", "509"}

# 429 / 限额 / 并发类关键词：模型没坏，是额度或并发踩线
SOFT_KEYWORDS = [
    "429", "rate limit", "rate_limit", "rate-limit", "too many requests",
    "quota", "insufficient_quota", "限额", "限流", "限率", "额度", "余额不足",
    "concurrent", "并发", "at most", "requests per", "rpm", "tpm",
    "no_available_channel", "超出", "insufficient balance",
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
    try:
        return int(time.mktime(time.strptime(s, "%Y/%m/%d - %H:%M:%S")))
    except Exception:
        return 0


def is_soft(code, content):
    """判断错误是否属于 429/限额/并发类（不算模型坏）"""
    if code in SOFT_CODES:
        return True
    low = (content or "").lower()
    for kw in SOFT_KEYWORDS:
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
    stat = defaultdict(lambda: {"ok": [], "hard": [], "soft": []})
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
                elif code in HARD_CODES:
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
    payload = json.dumps({"model": model, "status": status}).encode()
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

    # ---- 盲区名单：models.txt 有、但日志中完全无记录 → 需主动兜底探测 ----
    blind = []
    try:
        mt_path = os.environ.get("MODEL_LIST", "/app/models.txt")
        full = []
        for m in open(mt_path, errors="replace").read().split("\n"):
            m = m.strip()
            if m and not m.startswith("#"):
                full.append(m.lower())
        blind = sorted(set(full) - set(stat.keys()))
        os.makedirs("/tmp/passive_state", exist_ok=True)
        with open("/tmp/passive_state/blind_models.txt", "w") as f:
            f.write("\n".join(blind) + ("\n" if blind else ""))
        print(f"[passive] 被动盲区 {len(blind)} 个 → /tmp/passive_state/blind_models.txt")
    except Exception as e:
        print(f"[passive] 盲区计算失败: {e}", file=sys.stderr)

    counts = Counter()
    rows = []
    for model, s in sorted(stat.items()):
        ok = [t for t in s["ok"] if now - t <= WINDOW]
        hard = [t for t in s["hard"] if now - t <= WINDOW]
        soft = [t for t in s["soft"] if now - t <= WINDOW]

        if ok:
            verdict = "LIVE"
            prev[model] = 0
        elif hard:
            streak = prev.get(model, 0) + len(hard)
            prev[model] = streak
            verdict = "DEAD" if streak >= DEAD_STREAK else None
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

    for model, v, o, h, s_, put in rows:
        warn = "" if put else "  [PUT失败/未登记]"
        note = "  <-含429证据仍判活(不误杀)" if (s_ and v == "LIVE") else ""
        print(f"  {model:42s} {v:4s} ok={o:<3d} hard={h:<3d} soft={s_:<3d}{warn}{note}")

    save_state(prev)
    print(f"\n[passive] LIVE={counts['LIVE']} DEAD={counts['DEAD']} "
          f"(含429证据仍判活={counts['had_soft']}) 观察中={counts['skip']} 盲区={len(blind)}")
    print("[passive] 规则: 纯429/限额一律不判死 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
