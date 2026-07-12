# lib_nu1680 -- NU1680 无线充电芯片驱动

NU1680 是无线充电接收端电源管理芯片，通过 I2C 接口配置过流保护和温度保护参数。

## 寄存器

| 寄存器 | 名称 | 位域 | 描述 |
|--------|------|------|------|
| `0x1E` | `MTP_ILIM_SET` | [2:0] | 过流保护电流限制 |
| `0x15` | 温度保护 | [7:0] | 写 0x00 关闭，非零开启 |

### 电流限值表 (0x1E[2:0])

| [2:0] | 电流 (mA) |
|-------|-----------|
| `000` | 1400 |
| `001` | 1650 |
| `010` | 1100 |
| `011` | 740 |
| `100` | 365 |
| `101` | 450 |
| `110` | 290 |
| `111` | 215 |

> 写入时只修改低 3 位，高 5 位保持不变。

## API

### `nu1680.new(opts?)`

创建 NU1680 驱动实例。

`opts` 参数（可选）：
- `port` (number) I2C 端口号（必需，除非提供 `bus`）
- `sda` (number) SDA GPIO（必需，除非提供 `bus`）
- `scl` (number) SCL GPIO（必需，除非提供 `bus`）
- `freq_hz` / `frequency` (number) I2C 频率，默认 400000
- `addr` (number) I2C 地址，默认 0x60
- `bus` (i2c.bus) 共享 I2C 总线（如果提供则忽略 port/sda/scl）

### `dev:configure()`

标准初始化：设置 1.4A 电流限制 + 关闭温度保护。

### `dev:set_current_limit(ilim_code)`

设置过流保护电流限制。`ilim_code` 取值 0-7，见上表。

### `dev:get_current_limit()`

返回当前电流限制设置 (mA)。

### `dev:read_ilim_reg()`

读取并打印寄存器 0x1E 的原始值。

### `dev:read_therm_reg()`

读取并打印寄存器 0x15 的原始值。

### `dev:enable_thermal_protection()`

开启温度保护。

### `dev:disable_thermal_protection()`

关闭温度保护。

### `dev:close()`

释放 I2C 资源。

## 示例

```lua
local nu1680 = require("lib_nu1680")
local dev = nu1680.new({ port = 1, sda = 7, scl = 8 })

-- 标准配置 (1.4A / 关闭温度保护)
dev:configure()

-- 读取当前设置
local current = dev:get_current_limit()
print("Current limit:", current, "mA")

dev:close()
```
