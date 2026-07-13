# Lua GPS NMEA Parser

Pure Lua driver for NMEA-0183 GPS modules over UART.

## How to call

```lua
local gps = require("lib_gps")

local g = gps.new({ port = 0, tx = 38, rx = 37, baud = 9600 })

-- Poll periodically to drain UART and parse NMEA sentences
g:poll()

local s = g:get_snapshot()
print(string.format("fix=%s lat=%.6f lon=%.6f sats=%d/%d",
    s.fix_valid and "YES" or "NO",
    s.latitude_deg, s.longitude_deg,
    s.satellites_used, s.satellites_view))

g:close()
```

## Options

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `port` | integer | - | UART port number |
| `tx` | integer | - | TX GPIO pin |
| `rx` | integer | - | RX GPIO pin |
| `baud` | integer | 9600 | Baud rate |
| `bus` | userdata | - | Existing UART handle |

## Methods

- `g:poll()` - drain UART, parse NMEA sentences, return lines processed
- `g:get_snapshot()` - return current GPS state table
- `g:close()` - release UART resources

## Supported NMEA sentences

- GGA: position, fix quality, altitude, satellites used
- RMC: speed, date, status
- GSV: satellites in view (multi-constellation: GP/GL/GA/BD/GN)
