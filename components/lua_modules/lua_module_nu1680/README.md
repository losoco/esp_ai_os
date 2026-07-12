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

## 参考

- 芯片: NU1680 (I2C 0x60)
- 参考实现: MetalioClaw4 `metalio-claw-4.cc` Wxcho class
