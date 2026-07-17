# Display App Exit Recovery Notes

## 背景

从 launcher 启动 `wifi_control` 后，应用能正常响应，但上滑退出时偶发无法回到 launcher。

典型日志：

```text
boot_launcher: Swipe UP ..., stopping scripts
lua --jobs
... | running | name=wifi_control | exclusive=display | ...
```

或：

```text
... | stopped | name=wifi_control | exclusive=display | ...
```

但没有出现：

```text
display_arbiter: display owner changed to emote
boot_launcher: Display returned to emote
```

## 根因要点

### 1. `exclusive=display` 是脚本互斥/停止分组

`exclusive=display` 表示该 Lua async job 是前台显示应用，占用 display 资源组。

它不是实际屏幕所有权；实际屏幕所有权由 `display_arbiter` 管理。

两者职责不同：

| 机制 | 作用 |
| --- | --- |
| `exclusive=display` | Lua async job 的互斥和批量停止分组 |
| `display_arbiter` | 真实 display owner 状态切换，决定 launcher 何时恢复 |

`boot_launcher` 的 `exclusive=none` 是合理的，因为它是系统 launcher worker，不应该被上滑批量停止，也不应该阻塞前台 app 启动。

### 2. 上滑停止不应解析 `lua --jobs` 文本

旧逻辑通过：

1. `cap_lua_list_jobs()` 输出文本
2. 解析每一行 job id
3. 对非 launcher job 调用 `cap_lua_stop_job()`

这个方案脆弱：

- 输出 buffer 可能截断
- 文本格式变化会导致解析漏掉 job
- terminal job 和 running job 混在一起时容易误判

更可靠的策略是直接调用：

```c
cap_lua_stop_all_jobs("display", SCRIPT_STOP_WAIT_MS, output, sizeof(output));
```

由 `cap_lua_async` 内部按 job slot 和 `exclusive=display` 查找运行中的前台显示应用。

### 3. Lua job 停止后必须兜底释放 display owner

`wifi_control` 被 stop 时可能停在阻塞点，例如：

```text
[C]: in function 'delay.delay_ms'
.../wifi_control/main.lua:173: stop requested
```

如果脚本没成功执行到 Lua 层的 `display.deinit()`，job 会进入 stopped，但 display owner 仍可能卡在 `LUA`。

因此 display 模块需要在 Lua state 退出 cleanup 中兜底：

- 记录哪个 Lua state 成功执行了 `display.init()`
- 该 Lua state 退出时，如果仍是 display owner，则执行 `display_arbiter_release(DISPLAY_ARBITER_OWNER_LUA)`

### 4. display HAL destroy 要执行，但不能阻止 arbiter release

`display_hal_destroy()` 需要执行，因为它会释放 display 模块内部锁、flush 状态和运行时资源。

但它不能成为释放 display owner 的前置条件。否则一旦 destroy 因 flush 等待等原因返回错误，`display_arbiter_release()` 就不会执行，launcher 会等不到 owner 回到 `EMOTE`。

修复原则：

```c
esp_err_t destroy_err = display_hal_destroy();
esp_err_t release_err = display_arbiter_release(DISPLAY_ARBITER_OWNER_LUA);
```

要求：

- `display_hal_destroy()` 必须执行，用于释放内部状态
- `display_arbiter_release()` 也必须执行，用于恢复系统 display owner
- cleanup 路径里 destroy 失败只打 warning，不阻止 owner release
- 显式 `display.deinit()` 可以把 destroy/release 的错误返回给 Lua，但两步都要先执行完

## 正确恢复链路

```text
用户上滑
  -> boot_launcher motion_swipe_up
  -> cap_lua_stop_all_jobs("display", ...)
  -> cap_lua_async 设置 stop_requested
  -> display app 退出 / cleanup 兜底释放 display
  -> display_arbiter owner changed to emote
  -> boot_launcher 延迟检查 active_count == 0
  -> launcher_run()
```

## 验证日志

成功时应看到：

```text
boot_launcher: Swipe UP ..., stopping scripts
cap_lua_async: Stop requested for job ... (name=wifi_control)
boot_launcher: Stopped ... job(s), ... still unwinding (filter=display)
display_arbiter: display owner changed to emote
boot_launcher: Display returned to emote, scheduling deferred launcher restart
boot_launcher: No active scripts, restarting launcher
```

如果只看到 `Swipe UP`，但没有 `Stop requested`，优先检查 `exclusive=display` 和 `cap_lua_stop_all_jobs("display")` 路径。

如果 job 已经 `stopped`，但没有 `display owner changed to emote`，优先检查 display cleanup / `display_arbiter_release()` 路径。
