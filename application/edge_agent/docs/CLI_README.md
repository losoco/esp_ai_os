# ESP-Claw CLI 工具文档

`esp-claw-cli.py` 是一个类似 ADB 的命令行工具，用于通过 WiFi HTTP 与 ESP-Claw 设备交互。

**位置**: `tools/esp-claw-cli/esp-claw-cli.py`

**依赖**: Python 3.8+（无需额外安装 pip 包，核心功能仅使用标准库）

---

## 快速开始

```bash
# 查看设备状态（默认连接 esp-claw.local）
python3 tools/esp-claw-cli/esp-claw-cli.py info

# 指定 IP
python3 tools/esp-claw-cli/esp-claw-cli.py --host 192.168.8.100 info

# 查看帮助
python3 tools/esp-claw-cli/esp-claw-cli.py --help
```

---

## 命令列表

| 命令 | 功能 | 传输方式 |
|------|------|----------|
| `push` | 上传文件到设备 SD 卡 | HTTP POST |
| `pull` | 从设备 SD 卡下载文件 | HTTP GET |
| `ls` | 列出远程目录内容 | HTTP GET |
| `rm` | 删除远程文件/目录 | HTTP DELETE |
| `mkdir` | 创建远程目录 | HTTP POST |
| `run` | 上传并运行 Lua 脚本 | HTTP (上传 + 执行 + 轮询) |
| `exec` | 执行 Lua 一行代码 | HTTP (上传 + 执行 + 轮询) |
| `stop` | 停止正在运行的 Lua 作业 | HTTP POST |
| `jobs` | 查看 Lua 异步作业列表 | HTTP GET |
| `shell` | 串口交互终端 | 串口 (需要 pyserial) |
| `discover` | mDNS 发现局域网设备 | mDNS (需要 zeroconf) |
| `info` | 查看设备状态 | HTTP GET |

---

## 使用示例

### 文件传输

```bash
# 上传文件
python3 tools/esp-claw-cli/esp-claw-cli.py push app.lua /inbox/app.lua

# 下载文件
python3 tools/esp-claw-cli/esp-claw-cli.py pull /sdcard/capture.jpg ./photo.jpg

# 列出 SD 卡根目录
python3 tools/esp-claw-cli/esp-claw-cli.py ls /

# 递归删除目录
python3 tools/esp-claw-cli/esp-claw-cli.py rm -r /inbox/old_stuff/

# 创建多级目录
python3 tools/esp-claw-cli/esp-claw-cli.py mkdir -p /inbox/level1/level2
```

### Lua 脚本执行（纯 HTTP，无需串口）

```bash
# 上传本地脚本并运行（自动上传→执行→等待完成→打印结果）
python3 tools/esp-claw-cli/esp-claw-cli.py run my_script.lua --timeout-ms 60000 --wait 120

# 运行设备上已有的脚本（不重新上传）
python3 tools/esp-claw-cli/esp-claw-cli.py run --no-upload /inbox/gauge_test.lua

# 带 JSON 参数
python3 tools/esp-claw-cli/esp-claw-cli.py run test.lua --args-json '{"port":1,"sda":7}'

# 执行一行 Lua 代码
python3 tools/esp-claw-cli/esp-claw-cli.py exec "print('Hello! '..os.time())"

# 调整轮询间隔和超时
python3 tools/esp-claw-cli/esp-claw-cli.py exec "for i=1,100 do print(i) end" --poll 0.5 --wait 30 --timeout-ms 30000
```

### 作业管理

```bash
# 查看所有作业
python3 tools/esp-claw-cli/esp-claw-cli.py jobs

# 查看特定作业详情
python3 tools/esp-claw-cli/esp-claw-cli.py jobs <job_id>

# 停止正在运行的作业
python3 tools/esp-claw-cli/esp-claw-cli.py stop <job_id>
```

### 其他

```bash
# 串口终端
python3 tools/esp-claw-cli/esp-claw-cli.py shell --port /dev/cu.usbmodem31101

# mDNS 发现设备
python3 tools/esp-claw-cli/esp-claw-cli.py discover

# 查看状态
python3 tools/esp-claw-cli/esp-claw-cli.py info
```

---

## run/exec 命令参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--timeout-ms` | run=60000, exec=30000 | 脚本执行超时（毫秒），0=不限 |
| `--poll` | run=1.5, exec=1.0 | 状态轮询间隔（秒） |
| `--wait` | run=120, exec=60 | 最长等待时间（秒） |
| `--no-upload` | false | 跳过上传，直接运行设备上已有脚本 |
| `--args-json` | 无 | 传递给 Lua 脚本的 JSON 参数 |

---

## 工作原理

### 文件操作 (push/pull/ls/rm/mkdir)

通过设备 HTTP 服务器的文件 API：
- `push` → `POST /api/files/upload?path=<path>`（原始二进制 body）
- `pull` → `GET /files/<path>`（流式下载）
- `ls` → `GET /api/files?path=<path>`（JSON 响应）
- `rm` → `DELETE /api/files?path=<path>`
- `mkdir` → `POST /api/files/mkdir`（JSON body）

### Lua 执行 (run/exec)

通过新添加的异步执行 API：

1. **上传**（仅 run/exec 非 `--no-upload` 模式）：
   - 上传 Lua 脚本到 `/inbox/<filename>`
2. **启动执行**：`POST /api/files/run` `{"path": "/inbox/test.lua", "timeout_ms": 60000}`
   - 后端调用 `cap_lua_run_script_async()` 异步启动脚本
   - 返回 `{"ok": true, "job_id": "a1b2c3d4"}`
3. **轮询状态**：`GET /api/files/run/<job_id>`
   - 每 `--poll` 秒查询一次
   - 返回 `{"status": "running", "runtime_s": 5, "recent_log": "..."}`
4. **完成/超时**：
   - `status=done` → 打印 `completed in Xs`
   - `status=timeout` → 打印 `timed out`
   - `status=failed` → 打印错误信息
5. **停止**：`POST /api/files/run/<job_id>/stop`

---

## 网页文件管理器

设备 Web 界面 `http://esp-claw.local/#files` 也支持 Lua 脚本运行：

- ▶ **运行按钮**: 每个 `.lua` 文件旁都有播放按钮
- ■ **停止按钮**: 运行中的作业在顶部状态栏显示，可随时停止
- 运行状态实时更新（路径、运行时长、脉冲指示器）

---

## 路径说明

- HTTP 文件 API 使用**相对路径**：`/inbox/test.lua` → SD 卡上的 `/sdcard/inbox/test.lua`
- `run --no-upload` 路径同样使用相对路径：`/inbox/test.lua`
- `pull` 使用 HTTP 下载路径：`/inbox/test.lua`（不用加 `/sdcard` 前缀）
- CLI 自动处理 `/sdcard` 前缀转换

---

## 故障排除

| 问题 | 解决方法 |
|------|----------|
| `Connection failed` | 确认设备 WiFi 已连接，IP 正确 |
| `File not found` | 检查路径是否以 `/` 开头，不需要 `/sdcard` 前缀 |
| `Run failed: HTTP 400` | 检查脚本路径是否有效，`.lua` 后缀是否正确 |
| `HTTP 404` (pull) | 文件不存在，先用 `ls` 确认路径 |
| `Script still running` | 脚本执行超时但未完成，增加 `--wait` 参数 |
| 串口连接导致设备重启 | ESP32-P4 USB-Serial-JTAG 特性，使用 HTTP 命令避免 |
