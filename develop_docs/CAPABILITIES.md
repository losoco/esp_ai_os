# ESP AI OS — Capability Reference

每个 Capability 通过 `capability.call(family, id, args)` 从 Lua 调用。本文档列出所有已注册的 Capability。

---

## 调用方式

```lua
local capability = require("capability")

-- 无参数调用
capability.call("system", "restart_device")

-- 带参数调用 (JSON string)
capability.call("automation", "lua_run_script", '{"path":"/sdcard/apps/demo/main.lua"}')

-- pcall 安全调用
pcall(capability.call, "system", "web_search", '{"query":"ESP32-P4 datasheet"}')
```

---

## Capability 列表 (60 个)

### system 族 (8 个)

| ID | 说明 |
|----|------|
| `restart_device` | 重启设备，可选 `delay_ms` 参数（毫秒） |
| `get_system_info` | 获取系统信息：chip, uptime, version, memory, cpu, wifi, ip |
| `get_current_time` | 获取当前时间 |
| `web_search` | 搜索引擎查询，参数 `query` |
| `http_request` | HTTP 请求（白名单保护） |
| `run_cli_command` | 执行 CLI 命令 |
| `inspect_image` | 分析本地图片，参数 `path` + `prompt` |
| `session_command` | 会话管理命令 |

### files 族 (6 个)

| ID | 说明 |
|----|------|
| `read_file` | 读取文件内容 |
| `write_file` | 创建或覆盖文件 |
| `delete_file` | 删除文件 |
| `copy_file` | 复制文件 |
| `move_file` | 移动文件 |
| `list_dir` | 递归列出目录内容 |

### automation 族 (7 个)

| ID | 说明 |
|----|------|
| `lua_run_script` | 同步运行 Lua 脚本 |
| `lua_run_script_async` | 异步运行 Lua 脚本（返回 job_id） |
| `lua_list_async_jobs` | 列出异步任务 |
| `lua_get_async_job` | 获取任务状态和日志 |
| `lua_tail_async_job` | 增量读取任务日志 |
| `lua_stop_async_job` | 停止指定任务 |
| `lua_stop_all_async_jobs` | 停止所有任务 |

### agent_mgr 族 (6 个)

| ID | 说明 |
|----|------|
| `spawn_agent` | 创建异步子 Agent |
| `send_agent_followup` | 向子 Agent 发送后续消息 |
| `inspect_agent` | 检查子 Agent 状态 |
| `list_agents` | 列出所有子 Agent |
| `close_agent` | 关闭子 Agent |
| `delete_agent` | 删除子 Agent 及其历史 |

### im 族 (15 个)

| ID | 平台 | 说明 |
|----|------|------|
| `local_gateway` | 本地 | 本地 IM 网关 |
| `local_send_message` | 本地 | 发送本地消息 |
| `qq_gateway` | QQ | QQ Bot 网关 |
| `qq_send_message` | QQ | 发送 QQ 消息 |
| `qq_send_image` | QQ | 发送 QQ 图片 |
| `qq_send_file` | QQ | 发送 QQ 文件 |
| `feishu_gateway` | 飞书 | 飞书 WebSocket 网关 |
| `feishu_send_message` | 飞书 | 发送飞书消息 |
| `feishu_send_image` | 飞书 | 发送飞书图片 |
| `feishu_send_file` | 飞书 | 发送飞书文件 |
| `wechat_gateway` | 微信 | 微信长轮询网关 |
| `wechat_send_message` | 微信 | 发送微信消息 |
| `wechat_send_image` | 微信 | 发送微信图片 |
| `tg_gateway` | Telegram | Telegram 轮询网关 |
| `tg_send_message` | Telegram | 发送 TG 消息 |
| `tg_send_image` | Telegram | 发送 TG 图片 |
| `tg_send_file` | Telegram | 发送 TG 文件 |

### mcp 族 (3 个)

| ID | 说明 |
|----|------|
| `mcp_list_tools` | 列出远程 MCP 服务工具 |
| `mcp_call_tool` | 调用远程 MCP 服务工具 |
| `mcp_discover` | 发现局域网 MCP 服务 |

### router_manager 族 (6 个)

| ID | 说明 |
|----|------|
| `list_router_rules` | 列出所有路由规则 |
| `get_router_rule` | 获取单条路由规则 |
| `add_router_rule` | 添加路由规则 |
| `update_router_rule` | 更新路由规则 |
| `delete_router_rule` | 删除路由规则 |
| `reload_router_rules` | 从磁盘重新加载路由规则 |

### scheduler 族 (10 个)

| ID | 说明 |
|----|------|
| `scheduler_list` | 列出所有调度任务 |
| `scheduler_get` | 获取单个调度任务 |
| `scheduler_add` | 添加调度任务 |
| `scheduler_update` | 更新调度任务 |
| `scheduler_enable` | 启用调度任务 |
| `scheduler_disable` | 禁用调度任务 |
| `scheduler_remove` | 移除调度任务 |
| `scheduler_pause` | 暂停调度任务 |
| `scheduler_resume` | 恢复调度任务 |
| `scheduler_trigger_now` | 立即触发调度任务 |

### skill 族 (4 个)

| ID | 说明 |
|----|------|
| `list_skill` | 列出所有技能 |
| `register_skill` | 注册/刷新技能 |
| `unregister_skill` | 删除技能 |
| `activate_skill` | 激活技能（返回技能文档） |

### app 族 (1 个)

| ID | 说明 |
|----|------|
| `llm_config_command` | LLM 配置命令 |

---

## Launcher 常用调用

```lua
local capability = require("capability")

-- 重启设备 (已用于 Settings > Reboot 按钮)
capability.call("system", "restart_device")

-- 列出异步任务
capability.call("automation", "lua_list_async_jobs")

-- 停止指定名称的异步任务
capability.call("automation", "lua_stop_async_job", '{"name":"sensor_hub"}')

-- 获取系统信息
capability.call("system", "get_system_info", '{"sections":["chip","uptime","version","memory"]}')

-- 搜索
capability.call("system", "web_search", '{"query":"hello world"}')
```

---

## 代码位置

所有 Capability 注册位于 `components/claw_capabilities/cap_*/src/cap_*.c`，通过 `claw_cap_descriptor_t` 结构体定义，`.id` 字段即为调用时使用的 ID。
