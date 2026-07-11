# Lua SC7A20H Accelerometer

Pure Lua driver for the SC7A20H / LIS2DH12 3-axis accelerometer over I2C.

## How to call

```lua
local sc7a20h = require("lib_sc7a20h")
local i2c = require("i2c")

local bus = i2c.new(1, 7, 8, 400000)
local accel = sc7a20h.new({ bus = bus, addr = 0x19 })

local ax, ay, az = accel:read_mg()   -- milli-g
local gx, gy, gz = accel:read_g()    -- g (9.8 m/s²)

print(string.format("X=%.3fg Y=%.3fg Z=%.3fg", gx, gy, gz))
accel:close()
bus:close()
```

## Options

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `bus` | userdata | — | Existing I2C bus handle |
| `port` | integer | — | I2C port number |
| `sda` | integer | — | SDA GPIO |
| `scl` | integer | — | SCL GPIO |
| `freq_hz` | integer | 400000 | I2C frequency |
| `addr` | integer | 0x19 | I2C 7-bit address |

## Methods

- `accel:read_mg()` — returns `ax, ay, az` in milli-g
- `accel:read_g()` — returns `ax, ay, az` in g
- `accel:whoami()` — returns WHO_AM_I register
- `accel:set_offset(ox, oy, oz)` — zero-offset calibration in mg
- `accel:close()` — release I2C resources

## Configuration

- ODR: 100 Hz
- Range: ±2g, high-resolution mode (12-bit, 1 mg/LSB)
- Compatible: LIS2DH12 register map
