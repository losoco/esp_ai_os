# Lua NT26 4G Modem

Pure Lua AT command interface for NT26 / ML307 4G LTE modem over UART.

## How to call

```lua
local nt26 = require("lib_nt26")

local m = nt26.new({ port = 1, tx = 28, rx = 29, baud = 2000000 })

if m:is_alive() then
    local csq = m:get_signal_strength()
    local imei = m:get_imei()
    print(string.format("CSQ=%s IMEI=%s", csq, imei))
end

m:close()
```

## Options

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `port` | integer | - | UART port number |
| `tx` | integer | - | TX GPIO pin |
| `rx` | integer | - | RX GPIO pin |
| `baud` | integer | 2000000 | Baud rate |
| `bus` | userdata | - | Existing UART handle |
| `expander` | userdata | - | TCA9555 IO expander for reset |
| `reset_pin` | integer | 7 | Reset pin on expander (P0-7) |

## Methods

- `m:send_at(cmd, timeout_ms)` - send AT command, return response string
- `m:is_alive()` - check modem responds to AT
- `m:get_signal_strength()` - return CSQ 0-31 or nil
- `m:get_imei()` - return IMEI string or nil
- `m:get_iccid()` - return ICCID string or nil
- `m:get_network_status()` - return CEREG stat, act
- `m:get_cell_info()` - return {tac, ci, csq} or nil
- `m:dial(number)` - make a call
- `m:hang_up()` - hang up call
- `m:reset()` - hardware reset via IO expander
- `m:close()` - release UART resources
