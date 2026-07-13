# lib_nt26

NT26 / ML307 4G LTE modem AT command interface over UART.

## API

### `nt26.new(opts) -> handle`

- `opts.port`: UART port number (required)
- `opts.tx`: TX GPIO pin (required)
- `opts.rx`: RX GPIO pin (required)
- `opts.baud`: baud rate (default 2000000)
- `opts.bus`: existing UART handle
- `opts.expander`: TCA9555 IO expander handle for reset control
- `opts.reset_pin`: reset pin on expander (default 7 = P0-7)

### `handle:send_at(cmd, timeout_ms) -> string`

Send AT command, collect response until OK/ERROR or timeout.

### `handle:is_alive() -> bool`

Send `AT` and check for `OK` response.

### `handle:get_signal_strength() -> int|nil`

Returns CSQ value 0-31, or nil if no signal (99).

### `handle:get_imei() -> string|nil`

### `handle:get_iccid() -> string|nil`

### `handle:get_network_status() -> stat, act`

Returns CEREG registration state and access technology.

### `handle:get_cell_info() -> table|nil`

Returns `{tac, ci, csq}` from ECBCINFO.

### `handle:dial(number) -> string`

### `handle:hang_up() -> string`

### `handle:reset()`

Hardware reset via IO expander.

### `handle:close()`
