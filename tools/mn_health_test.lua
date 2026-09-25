#!/usr/bin/env lua
-- mn_health_test.lua — 健康表功能 LuaJIT 单测
-- 用法: luajit mn_health_test.lua
-- 本地: cd NewAPI && luajit tools/mn_health_test.lua

-- 加载 cjson
local cjson = require("cjson.safe")

-- 健康表函数（从 default.conf 复制的纯 Lua 实现）
local function mn_health_key(model_id)
    return "health:" .. model_id:lower()
end

local function mn_health_get(cache, model_id)
    local v = cache:get(mn_health_key(model_id))
    if not v or #v == 0 then return nil end
    local ok, h = pcall(cjson.decode, v)
    if not ok or type(h) ~= "table" then return nil end
    if os.difftime(os.time(), h.last_probe_ts or 0) > 2700 then return nil end
    return h
end

local function mn_health_set(cache, model_id, status)
    cache:set(mn_health_key(model_id),
              cjson.encode({status=status, last_probe_ts=os.time(), consecutive_failures=status=="dead" and 2 or 0}),
              2700)
end

-- mock cache
local mock_cache = {
    _data = {},
    get = function(self, k) return self._data[k] end,
    set = function(self, k, v) self._data[k] = v end,
    delete = function(self, k) self._data[k] = nil end,
}

local tests = 0
local passed = 0

local function check(name, cond, detail)
    tests = tests + 1
    if cond then
        passed = passed + 1
    else
        print("FAIL: " .. name .. (detail and (" (" .. detail .. ")") or ""))
    end
end

-- === 单测 ===

check("mn_health_key 格式", mn_health_key("gemini-3.8-flash") == "health:gemini-3.8-flash")

check("mn_health_get 初始 nil", mn_health_get(mock_cache, "nonexistent") == nil)

mn_health_set(mock_cache, "test-model", "dead")
local h = mn_health_get(mock_cache, "test-model")
check("mn_health_set/get 往返", h ~= nil and h.status == "dead")

mn_health_set(mock_cache, "test-suspect", "suspect")
local h2 = mn_health_get(mock_cache, "test-suspect")
check("mn_health_set 接受 suspect", h2 ~= nil and h2.status == "suspect")

-- TTL 过期测试（模拟时间戳非常旧）
local old_ts = tostring(os.time() - 3000)  -- 50 分钟前
mock_cache._data["health:expired"] = '{"status":"dead","last_probe_ts":' .. old_ts .. '}'
local h3 = mn_health_get(mock_cache, "expired")
check("TTL 过期视为未知", h3 == nil)

-- 死模型过滤
local alive = mn_health_get(mock_cache, "alive-model")
mn_health_set(mock_cache, "alive-model", "suspect")
local alive2 = mn_health_get(mock_cache, "alive-model")
check("TTL 内返回非 nil", alive2 ~= nil and alive2.status == "suspect")

-- delete
mock_cache:delete("test-model")
local h4 = mn_health_get(mock_cache, "test-model")
check("delete 后返回 nil", h4 == nil)

-- 空 key
local ok, err = pcall(mn_health_key, "")
check("空 key 不崩", ok)

print(string.format("\n=== 单测汇总: PASS=%d/%d ===", passed, tests))
if passed < tests then os.exit(1) end
