---
{
  "name": "bt_audio",
  "description": "Switch the Bluetooth audio chip operating mode (local playback, BT pairing, music receive). Use before playing local audio or when the user wants to connect Bluetooth headphones.",
  "metadata": {
    "cap_groups": [
      "cap_lua"
    ],
    "manage_mode": "readonly"
  }
}
---

# BT Audio Mode Switch

This skill controls the Bluetooth audio chip's operating mode via UART AT
commands. The BT chip is the I2S clock master — it must be in **local mode**
before the ESP32 can play audio through the speaker.

## Modes

| Mode | Description | When to use |
|------|-------------|-------------|
| `local` | ESP32 plays audio locally through the speaker | Before any local audio playback, TTS, or voice interaction |
| `pair` | BT chip scans and pairs with headphones/speakers | When user wants to connect Bluetooth audio devices |
| `music` | Phone streams music to the device | When user wants to use the device as a Bluetooth speaker |

## Quick usage

Run the switch script with the desired mode:

```text
lua --run --path {CUR_SKILL_DIR}/scripts/switch_mode.lua --args-json {"mode":"local"}
```

## Direct API usage

You can also call the library directly in Lua:

```lua
local bt_audio = require("bt_audio")

-- Ensure local playback mode before playing audio
local ok, err = bt_audio.ensure_local()
if not ok then
    print("switch failed: " .. tostring(err))
end
```

## Important notes

- The BT chip remembers its mode across reboots. If it was previously
  connected to a phone, you must call `local` mode before playing audio
  from the ESP32.
- Mode switching takes about 1 second (700ms gap between AT commands +
  200ms settle). The script handles this automatically.
- The UART port is released after each switch so other scripts can use it.
