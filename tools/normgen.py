#!/usr/bin/env python3
# normgen v3 — 最终版：产出
#   /tmp/synth_table.lua (conf 用 SYNTH_REWRITE 表, BEGIN/END 标记)
#   /tmp/expect.lua      (LuaJIT 单测用期望值)
import json, re
from collections import Counter

raw = [m['id'] for m in json.load(open('/tmp/raw_ids.json'))['data'] if m.get('id')]
rawlower = set(x.lower() for x in raw)
live = [m['id'] for m in json.load(open('/tmp/gw_now.json'))['data']]

def canon(c):
    c = c.lower()
    c = re.sub(r'[\s_.]+', '-', c); c = re.sub(r'-+', '-', c)
    c = re.sub(r'^[^/]+/', '', c)
    c = re.sub(r'[-:]free$', '', c)
    c = re.sub(r'-\d{8}$', '', c); c = re.sub(r'-\d{6}$', '', c); c = re.sub(r'-\d{4}$', '', c)
    c = re.sub(r'[-:]thinking$', '', c)
    c = re.sub(r'[-:]thinking[-:][a-z0-9]+$', '', c)
    c = re.sub(r'-(high|low|medium)$', '', c)
    return c

MSUF = ['-1', '-200k', '-lite', '-preview']
def merged_key(id, idset):
    k = canon(id); lo = id.lower()
    for suf in MSUF:
        if len(lo) > len(suf) and lo.endswith(suf):
            base = lo[:-len(suf)]
            if base in idset: return canon(base), base
    return k, None

def rank(s):
    sl = s.lower(); r = 0
    if '/' in s: r += 8
    if re.search(r'[-:]free$', sl): r += 4
    if re.search(r'-\d{8}$', sl) or re.search(r'-\d{6}$', sl) or re.search(r'-\d{4}$', sl): r += 2
    if s != sl: r += 1
    return r

def pipeline(ids, smart):
    idset = set(x.lower() for x in ids)
    group, order, merges = {}, [], []
    for id in ids:
        if smart:
            key, base = merged_key(id, idset)
            if base: merges.append((id, base))
        else:
            key = canon(id)
        if key not in group:
            group[key] = {'name': id, 'rank': rank(id)}; order.append(key)
        else:
            h = group[key]; r = rank(id)
            if r < h['rank'] or (r == h['rank'] and len(id) < len(h['name'])):
                group[key] = {'name': id, 'rank': r}
    return [group[k]['name'] for k in order], merges

old_disp, _ = pipeline(raw, False)
new_disp, merges = pipeline(raw, True)
assert set(live) == set(old_disp), "复刻校验失败"

TIER = r'-(?:lite|mini|nano|pro|max|plus|ultra|air)$'
def strip_na(lo):
    """返回 (结果, 命中的类)。类: free/high/date/lite/preview/exp/200k/tier"""
    c2 = re.sub(r'[-:]free$', '', lo)
    if c2 != lo: return c2, 'free'
    c2 = re.sub(r'-(high|low|medium)$', '', lo)
    if c2 != lo: return c2, 'high'
    for pat, cls in [(r'-\d{8}$','date8'), (r'-\d{6}$','date6'), (r'-\d{4}$','date4')]:
        c2 = re.sub(pat, '', lo)
        if c2 != lo: return c2, cls
    c2 = re.sub(r'-(lite|preview|exp|200k)$', '', lo)
    if c2 != lo:
        cls = re.match(r'.*-(lite|preview|exp|200k)$', lo).group(1)
        return c2, cls
    return lo, None

def tier_guard(base, self_lower):
    for x in rawlower:
        if x != self_lower and re.match('^' + re.escape(base) + TIER, x): return True
    return False

tentative = {}
for name in new_disp:
    lo = name.lower()
    I, cls = strip_na(lo)
    if I == lo:
        if lo.endswith('-1') and len(lo) > 3:
            tentative[name] = lo[:-2]
        continue
    if cls == 'lite' and tier_guard(I, lo):
        print(f"  [档位保护] 保持原样: {name} (基座 {I} 存在其它档位)")
        continue
    tentative[name] = I

dispA = {n: v for n, v in tentative.items() if v != n.lower()}
cnt = Counter(dispA.values())
kept_lows = set(n.lower() for n in new_disp if n not in dispA)
bad = set()
for k, v in list(dispA.items()):
    if cnt[v] > 1 or v in rawlower or v in kept_lows:
        bad.add(k); dispA.pop(k)
print(f"[A] 改名 {len(dispA)} 个, 冲突回退 {sorted(bad)}")

applied = dict(dispA)
for name in new_disp:
    cur = applied.get(name, name.lower())
    if cur.endswith('-1') and len(cur) > 3:
        cand = cur[:-2]
        finals = set(applied.values()) | set(n.lower() for n in new_disp if n not in applied) | rawlower
        finals.discard(cur)
        if cand not in finals:
            applied[name] = cand

pairs = sorted([(v, k) for k, v in applied.items()], key=lambda x: x[1])
print(f"[B] 合成对 {len(pairs)} 个")
final = [applied.get(n, n) for n in new_disp]
assert len(set(x.lower() for x in final)) == len(final), "display 重复!"
for d, t in pairs:
    assert d not in rawlower and t in rawlower and t in (n.lower() for n in new_disp), f"pair 校验失败 {d}<-{t}"
    # d 不得撞任何最终显示名
print(f"最终 {len(final)} 条")

# ---- 产出 conf 表 ----
lines = ["-- >>>SYNTH_BEGIN （由 normgen 生成；规则=显示名->真实名。改上游列表后重新生成，勿手改）",
         "MN_SYNTH_REWRITE = {"]
for d, t in pairs:
    lines.append(f'    ["{d}"] = "{t}",')
lines += ["}", "-- <<<SYNTH_END"]
open('/tmp/synth_table.lua', 'w').write("\n".join(lines) + "\n")

# ---- 产出 Lua 期望值 ----
el = ["-- 期望值（normgen 生成）", "EXPECT_MERGES = {"]
for id, base in merges: el.append(f'    ["{id}"] = "{base}",')
el += ["}", "EXPECT_PAIRS = {"]
for d, t in pairs: el.append(f'    ["{d}"] = "{t}",')
el += ["}", "EXPECT_OLD = {"]
for n in old_disp: el.append(f'    "{n}",')
el += ["}", "EXPECT_FINAL = {"]
for n in final: el.append(f'    "{n}",')
el += ["}"]
open('/tmp/expect.lua', 'w').write("\n".join(el) + "\n")

json.dump({'merges': merges, 'pairs': pairs, 'final': final, 'old': old_disp},
          open('/tmp/normgen_out.json', 'w'), ensure_ascii=False, indent=1)
print("已写 /tmp/synth_table.lua 和 /tmp/expect.lua")
print("\n=== 最终 23 对 ===")
for d, t in pairs: print(f"  {d:42s} <- {t}")
