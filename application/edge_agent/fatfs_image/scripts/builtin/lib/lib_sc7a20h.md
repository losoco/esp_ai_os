# lib_sc7a20h.lua

Reusable Lua driver for the SC7A20H / LIS2DH12 3-axis accelerometer. Uses the builtin `i2c` module.

## When to use

Use when a script needs 3-axis acceleration data (tilt, motion, orientation) from an SC7A20H connected over I2C.

## Loading

```lua
local sc7a20h = require("lib_sc7a20h")
```

## Constructor

```lua
local accel = sc7a20h.new(opts)
```

`opts` is a table:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `bus` | userdata | — | Existing I2C bus handle (recommended) |
| `port` | integer | — | I2C port (required if no `bus`) |
| `sda` | integer | — | SDA GPIO (required if no `bus`) |
| `scl` | integer | — | SCL GPIO (required if no `bus`) |
| `freq_hz` | integer | 400000 | I2C frequency in Hz |
| `frequency` | integer | — | Alias of `freq_hz` |
| `addr` | integer | 0x19 | 7-bit I2C address |

## Methods

- `accel:read_mg()` — returns `ax, ay, az` in milli-g (mg)
- `accel:read_g()` — returns `ax, ay, az` in g (9.8 m/s²)
- `accel:whoami()` — returns WHO_AM_I register value (0x11/0x32/0x33/0x44)
- `accel:set_offset(ox, oy, oz)` — set zero-offset calibration in mg
- `accel:close()` — close I2C device

## Configuration

- ODR: 100 Hz
- Range: ±2g
- Resolution: 12-bit, high-resolution mode
- Sensitivity: 1 mg/LSB

## Example

```lua
local sc7a20h = require("lib_sc7a20h")
local i2c = require("i2c")

local bus = i2c.new(1, 7, 8, 400000)
local accel = sc7a20h.new({ bus = bus, addr = 0x19 })

for i = 1, 10 do
    local ax, ay, az = accel:read_g()
    print(string.format("X=%.3fg Y=%.3fg Z=%.3fg", ax, ay, az))
end

accel:close()
bus:close()
```
