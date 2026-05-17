# Runtime Lua module

`runtime` provides Lua job management and named FreeRTOS-backed synchronization
objects shared by independent Lua async jobs.

## API

### `runtime.thread`

- `runtime.thread.run(path, args, opts)` runs an absolute `.lua` path
  synchronously and returns `true, output` or `nil, err`.
- `runtime.thread.start(path, args, opts)` starts an async Lua job and returns
  `true, output` or `nil, err`.
- `runtime.thread.list(status)` lists async jobs. `status` may be `all`,
  `queued`, `running`, `done`, `failed`, `timeout`, `stopped`, or nil.
- `runtime.thread.get(job_id_or_name)` returns job status, summary, and logs.
- `runtime.thread.stop(job_id_or_name, wait_ms)` requests cooperative stop.

`args` must be a table or nil. It is encoded as a JSON object and becomes the
child script's global `args` table. `opts.timeout_ms` controls runtime timeout;
async timeout `0` means run until cancelled. Async `opts` also accepts `name`,
`exclusive`, and `replace`.

### `runtime.sync`

- `runtime.sync.queue_create(name, opts)` creates a queue. `opts.depth` defaults
  to `8` and is limited to `1..32`; `opts.max_bytes` defaults to `2048` and is
  limited to `1..4096`.
- `runtime.sync.queue_send(name, value, timeout_ms)` sends boolean, number,
  string, or table values. `nil`, function, thread, and userdata values are not
  supported.
- `runtime.sync.queue_recv(name, timeout_ms)` returns the received value. It
  returns `nil, "timeout"` on timeout and `nil, "stopped"` when the Lua job is
  stopped.
- `runtime.sync.queue_delete(name)` deletes an idle empty queue. Queues with
  waiters or pending messages return `nil, "busy"`.
- `runtime.sync.sem_create(name, opts)` creates a counting semaphore.
  `opts.max` is `1..255` and `opts.initial` is `0..max`.
- `runtime.sync.sem_give(name)` gives a semaphore.
- `runtime.sync.sem_take(name, timeout_ms)` returns `true` on success,
  `false, "timeout"` on timeout, and `false, "stopped"` when the Lua job is
  stopped.
- `runtime.sync.sem_delete(name)` deletes an idle semaphore.
- `runtime.sync.lock_create(name)` creates a mutex lock.
- `runtime.sync.lock(name, timeout_ms)` returns `true` on success,
  `false, "timeout"` on timeout, and `false, "stopped"` when the Lua job is
  stopped.
- `runtime.sync.unlock(name)` unlocks a mutex. Only the Lua job task that
  acquired it can unlock it.
- `runtime.sync.lock_delete(name)` deletes an idle unlocked mutex.

Timeouts default to `0`, which means non-blocking. Permanent blocking is not
provided in the first version.

## Example

```lua
local runtime = require("runtime")

local ok, output = runtime.thread.run("/fatfs/scripts/builtin/test/runtime_child_a.lua", {
    mode = "sync",
}, {
    timeout_ms = 5000,
})
assert(ok, output)
print(output)

runtime.sync.queue_create("ui_cmd", { depth = 8, max_bytes = 2048 })
runtime.sync.queue_send("ui_cmd", { cmd = "set_text", text = "hello" }, 1000)
local msg, err = runtime.sync.queue_recv("ui_cmd", 500)
runtime.sync.queue_delete("ui_cmd")
```
