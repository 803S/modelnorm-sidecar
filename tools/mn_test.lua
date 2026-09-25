-- mn_test.lua — 网关 MODELNORM 区块 LuaJIT 单测（openresty 容器内运行）
-- 用法: luajit /tmp/mn_test.lua
local CONF = "/tmp/default.conf.mn"
local NAMES = "/tmp/mn_names.txt"
local EXPECT = "/tmp/expect.lua"

local npass, nfail = 0, 0
local function ok(c) npass = npass + 1; print("PASS: " .. c) end
local function bad(c) nfail = nfail + 1; print("FAIL: " .. c) end
local function check(c, cond) if cond then ok(c) else bad(c) end end

-- 1) 抽取并加载 MODELNORM 区块（与 conf 同源，杜绝逻辑分叉）
local fh = assert(io.open(CONF, "r")); local conf = fh:read("*a"); fh:close()
local b = conf:find(">>>MODELNORM_BEGIN", 1, true)
local e = conf:find("<<<MODELNORM_END", 1, true)
if not (b and e and e > b) then print("FATAL: 找不到 MODELNORM 标记"); os.exit(2) end
local chunk = conf:sub(b + #">>>MODELNORM_BEGIN", e - 1)
local fn, lerr = loadstring(chunk)
if not fn then print("FATAL: 区块 Lua 语法错误: " .. tostring(lerr)); os.exit(2) end
local p_ok, p_err = pcall(fn)
if not p_ok then print("FATAL: 区块执行错误: " .. tostring(p_err)); os.exit(2) end
ok("MODELNORM 区块 加载+执行")

local okE, errE = pcall(dofile, EXPECT)
if not okE then print("FATAL: expect.lua 加载失败: " .. tostring(errE)); os.exit(2) end

-- 2) 名单
local raw = {}
for line in io.lines(NAMES) do if line ~= "" then raw[#raw + 1] = line end end
local rawset = {}
for _, x in ipairs(raw) do rawset[x] = true end

local function setof(list) local s = {} for _, x in ipairs(list) do s[x] = true end return s end
local function nelem(s) local n = 0 for _ in pairs(s) do n = n + 1 end return n end
local function sets_equal(a, b)
    if #a ~= #b then return false end
    local sb = setof(b)
    for _, x in ipairs(a) do if not sb[x] then return false end end
    return true
end

-- 3) 管道（与 conf 中 content_by_lua_block 同构）
local idset = {}
for _, x in ipairs(raw) do idset[x:lower()] = true end

local function pipeline(smart)
    local group, order = {}, {}
    for _, x in ipairs(raw) do
        local key
        if smart then key = mn_merged_key(x, idset) else key = mn_canon_key(x) end
        local h = group[key]
        if not h then
            group[key] = { name = x, rank = mn_name_rank(x), id = x }
            order[#order + 1] = key
        else
            local r = mn_name_rank(x)
            if r < h.rank or (r == h.rank and #x < #h.name) then
                h.name = x; h.rank = r; h.id = x
            end
        end
    end
    local out = {}
    for _, key in ipairs(order) do
        local g = group[key]
        local d = MN_SYNTH_DISPLAY[g.name]
        if smart and d then g.id = d end
        out[#out + 1] = g.id
    end
    return out
end

local old = pipeline(false)
local new = pipeline(true)
check("老管道 == 期望（" .. #old .. " 条）", sets_equal(old, EXPECT_OLD))
check("新管道 == 期望（" .. #new .. " 条）", sets_equal(new, EXPECT_FINAL))
check("新管道显示名无重复", nelem(setof(new)) == #new)

-- 4) 条件归并：数量与名单精确匹配
local nwant = nelem(EXPECT_MERGES)
local got, extra = 0, {}
for _, x in ipairs(raw) do
    if mn_merged_key(x, idset) ~= mn_canon_key(x) then
        got = got + 1
        if not EXPECT_MERGES[x] then extra[#extra + 1] = x end
    end
end
check("条件归并数 = " .. nwant .. "（实际 " .. got .. "）", got == nwant)
check("归并无意外名单" .. (#extra > 0 and ("，额外: " .. table.concat(extra, ",")) or ""), #extra == 0)

-- 正/负样本
check("deepseek-v4.1-flash-1 → 归并到基名", mn_merged_key("deepseek-v4.1-flash-1", idset) == mn_canon_key("deepseek-v4.1-flash"))
check("mistral-ocr-4-1 不归并", mn_merged_key("mistral-ocr-4-1", idset) == mn_canon_key("mistral-ocr-4-1"))
check("claude-opus-4-1-20250805 key 不变", mn_merged_key("claude-opus-4-1-20250805", idset) == mn_canon_key("claude-opus-4-1-20250805"))
check("gpt-image-2 风格短数字名不受影响", mn_canon_key("gpt-image-2") == "gpt-image-2" and mn_canon_key("claude-opus-5") == "claude-opus-5")

-- 5) 合成表完整性
local npairs, pbad = 0, {}
for d, t in pairs(MN_SYNTH_REWRITE) do
    npairs = npairs + 1
    if rawset[d] then pbad[#pbad + 1] = "显示名撞真名:" .. d end
    if not rawset[t] then pbad[#pbad + 1] = "真实名缺失:" .. t end
    if MN_SYNTH_DISPLAY[t] ~= d then pbad[#pbad + 1] = "反查不一致:" .. t end
end
check("合成表 " .. npairs .. " 条（期望 " .. nelem(EXPECT_PAIRS) .. "）且配对一致", npairs == nelem(EXPECT_PAIRS) and #pbad == 0)
if #pbad > 0 then for i = 1, math.min(3, #pbad) do print("   ! " .. pbad[i]) end end

-- conf 表 vs 最新期望（漂移检查：上游列表变化后须重新生成合成表）
local drift = {}
for d, t in pairs(EXPECT_PAIRS) do if MN_SYNTH_REWRITE[d] ~= t then drift[#drift + 1] = d end end
for d, t in pairs(MN_SYNTH_REWRITE) do if EXPECT_PAIRS[d] ~= t then drift[#drift + 1] = d end end
check("conf 合成表 == 最新期望（无漂移）", #drift == 0)
if #drift > 0 then for i = 1, math.min(5, #drift) do print("   ! 漂移: " .. drift[i]) end end

-- 6) mn_rewrite_body 单测
local r1, v1, t1 = mn_rewrite_body('{"model":"gemini-3.8-flash","messages":[{"role":"user","content":"hi"}]}')
check("rewrite 命中: 精确改写+返回元组",
    r1 == '{"model":"gemini-3.8-flash-high","messages":[{"role":"user","content":"hi"}]}'
    and v1 == "gemini-3.8-flash" and t1 == "gemini-3.8-flash-high")

check("rewrite 非合成名: 原样", mn_rewrite_body('{"model":"deepseek-v4-flash","messages":[]}') == nil)
check("rewrite 容错空格", mn_rewrite_body('{"model" : "laguna-xs-2.1", "stream":true}') == '{"model":"laguna-xs-2.1:free", "stream":true}')
check("rewrite 截断JSON: 原样", mn_rewrite_body('{"model":"gemini-3.8-flash') == nil)
check("rewrite 空/nil: 原样", mn_rewrite_body("") == nil and mn_rewrite_body(nil) == nil)
local r5 = mn_rewrite_body('{"messages":[{"role":"user","content":"hi"}],"model":"hy4","stream":false}')
check("rewrite model非首键: 命中", r5 ~= nil and r5:find('"model":"hy4-preview"', 1, true) ~= nil)
check("rewrite 大小写不同: 不改(精确匹配)", mn_rewrite_body('{"model":"Gemini-3.8-Flash"}') == nil)
local r7 = mn_rewrite_body('{"model":"north-mini-code"}')
check("rewrite 全表抽查 north-mini-code", r7 == '{"model":"north-mini-code:free"}')

print(("== 单测汇总: PASS=%d FAIL=%d =="):format(npass, nfail))
os.exit(nfail == 0 and 0 or 1)
