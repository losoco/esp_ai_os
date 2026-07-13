# lib_gps

NMEA-0183 GPS parser over UART.

## API

### `gps.new(opts) -> handle`

- `opts.port`: UART port number (required)
- `opts.tx`: TX GPIO pin (required)
- `opts.rx`: RX GPIO pin (required)
- `opts.baud`: baud rate (default 9600)
- `opts.bus`: existing UART handle (skip internal `uart.new`)

### `handle:poll() -> int`

Drain UART RX buffer and parse complete NMEA sentences. Returns number of lines processed.

### `handle:get_snapshot() -> table`

Returns current GPS state:
- `fix_valid`, `fix_quality`, `latitude_deg`, `longitude_deg`, `altitude_m`
- `speed_kmh`, `satellites_used`, `satellites_view`, `hdop`
- `utc_time` ("HH:MM:SS"), `utc_date` ("YYYY-MM-DD")
- `sentence_count`, `bytes_received`

### `handle:close()`

Release UART resources.
