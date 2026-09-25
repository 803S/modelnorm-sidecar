# tools/ — 模型名归一化（MODELNORM）维护工具

对应构件：`openresty/default.conf` 里的 `init_by_lua_block`（MODELNORM 区）+ `location /` 的 rewrite 块。

## 两个自动化防线

1. **verify.sh**（回归入口，日常跑）：检查列表契约、合成对完整性（直接从 conf 解析，零副本漂移）、抽样折叠对、hy4 改写端到端。
2. **tools/mn_test.lua**（LuaJIT 单测，改规则/改表前后跑）：
   校验 老/新管道复刻、条件归并精确名单、合成表 vs 最新期望、`mn_rewrite_body` 全语义。

## 上游模型列表变化后的维护流程

```bash
cd /Users/lihua-dis/Software/Docker_compose/NewAPI
TOK=$(docker exec postgres psql -U root -d new-api -t -A -c "SELECT key FROM tokens WHERE id=1 LIMIT 1;" | tr -d ' ')
curl -s -m 15 http://127.0.0.1:3001/v1/models -H "Authorization: Bearer $TOK" > /tmp/raw_ids.json
# 1) 生成新表与期望值
python3 tools/normgen.py            # 输出 /tmp/synth_table.lua 与 /tmp/expect.lua，人眼过一遍变化
# 2) 把 /tmp/synth_table.lua 内容替换进 default.conf 的 >>>SYNTH_BEGIN/<<<SYNTH_END 之间
# 3) 单测（容器内）
python3 -c "import json;raw=[m['id'] for m in json.load(open('/tmp/raw_ids.json'))['data'] if m.get('id')];open('/tmp/mn_names.txt','w').write('\n'.join(raw)+'\n')"
docker cp openresty/default.conf openresty:/tmp/default.conf.mn
docker cp /tmp/mn_names.txt openresty:/tmp/mn_names.txt
docker cp /tmp/expect.lua openresty:/tmp/expect.lua
docker cp tools/mn_test.lua openresty:/tmp/mn_test.lua
docker exec openresty /usr/local/openresty/luajit/bin/luajit /tmp/mn_test.lua   # 期望全 PASS
# 4) 部署 + 回归
docker cp openresty/default.conf openresty:/etc/nginx/conf.d/default.conf
docker exec openresty /usr/local/openresty/bin/openresty -t && docker exec openresty /usr/local/openresty/bin/openresty -s reload
sleep 35 && bash verify.sh
```

## 注意

- 合成表由 normgen 从模型列表**推导**生成（档位家族如 Doubao-*-Lite/Mini/Pro 自动保护；-1 结尾带碰撞检查），**勿手改表**；要调整规则改 normgen.py 再重生成。
- canon 系函数内禁 while/组量词（LuaJIT pattern 限制，见 2026-09-21 事故笔记）。
- 改动前先备份 `openresty/default.conf`（历史备份如 default.conf.bak-20260921-fold2），回滚=换回备份+reload。
- 改 conf 后必须 `docker compose build openresty`（conf 是 COPY 进镜像的，不 build 则下次 recreate 会回退）。
