# lua_module_nu1680 -- NU1680 无线充电芯片驱动

纯 Lua I2C 驱动，用于 NU1680 无线充电接收端电源管理芯片。

## 寄存器

| 寄存器 | 名称 | 描述 |
|--------|------|------|
| `0x1E` | MTP_ILIM_SET | 过流保护电流限制 [2:0] |
| `0x15` | 温度保护 | 写 0x00 关闭 |

## 电流限值

0x1E[2:0]=0 → 1.4A, 1 → 1.65A, 2 → 1.1A, ... 7 → 0.215A

## 用法

```lua
local nu1680 = require("lib_nu1680")
local dev = nu1680.new({ port = 1, sda = 7, scl = 8 })
dev:configure()  -- 1.4A + 关闭温度保护
```

## 测试脚本

- `test/nu1680_read.lua` — 寄存器读写测试
- `test/nu1680_autoconf.lua` — 后台自动配置 + 显示通知（适配器检测 → 配置 → 开始/完成充电提示）

## autoconf 用法

```bash
# 后台运行（需先 push 到设备）
esp-claw-cli push nu1680_autoconf.lua /inbox/nu1680_autoconf.lua
esp-claw-cli run nu1680_autoconf.lua --timeout-ms 0  # timeout=0 = 不超时

# 或从网页 Files 页面点 ▶ 运行
```

**状态机**:
```
IDLE ──(适配器接入)──→ CHARGING ──(充满/移除)──→ FULL ──(适配器移除)──→ IDLE
      显示"开始充电"          显示"充电完成"              显示"充电完成"
```
