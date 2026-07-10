# lua_module_bt_audio

Bluetooth audio chip mode switching for boards with a BT audio module
connected via UART (AT commands) and I2S.

## Overview

The BT audio chip is the I2S clock master (provides BCLK/WS). It must be
in Mode 1 for the ESP32 to output local audio through the I2S slave
interface. This library sends AT commands over UART to switch between
three operating modes.

## Modes

| Mode | AT Commands | Description |
|------|-------------|-------------|
| local | `AT+RX=2` + `AT+MODE=1` | Local voice interaction (ESP32 -> I2S -> BT chip -> speaker) |
| pair | `AT+TX=1` + `AT+MODE=2` | BT pairing (connect to BT headphones/speakers) |
| music | `AT+RX=1` + `AT+MODE=3` | Music receive (phone -> device as BT speaker) |

## API

### `bt_audio.set_local_mode(opts?) -> ok, err`

Switch to Mode 1 (local playback). Call this before playing local audio.

### `bt_audio.set_pair_mode(opts?) -> ok, err`

Switch to Mode 2 (BT pairing mode).

### `bt_audio.set_music_mode(opts?) -> ok, err`

Switch to Mode 3 (music receive mode).

### `bt_audio.ensure_local(opts?) -> ok, err`

Alias for `set_local_mode()`. Ensures the BT chip is in local playback mode.

### `bt_audio.set_mode(mode, opts?) -> ok, err`

Switch to a mode by name: `"local"`, `"pair"`, or `"music"`.

## Options

All functions accept an optional `opts` table to override UART defaults:

```lua
bt_audio.set_local_mode({
    port = 2,       -- UART port number
    tx = 26,        -- TX GPIO pin
    rx = 27,        -- RX GPIO pin
    baud = 115200,  -- Baud rate
})
```

If `opts` is omitted, defaults are used (port=2, tx=26, rx=27, baud=115200).

## Usage

```lua
local bt_audio = require("bt_audio")

-- Switch to local playback before playing audio
local ok, err = bt_audio.ensure_local()
if not ok then
    print("BT mode switch failed: " .. tostring(err))
end
```
