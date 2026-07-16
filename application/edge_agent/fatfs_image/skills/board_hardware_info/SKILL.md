---
{
  "name": "board_hardware_info",
  "description": "Use this skill before operating hardware or writing Lua and board-specific code that depends on device inventory and occupied GPIOs.",
  "metadata": {
    "cap_groups": ["cap_boards"],
    "manage_mode": "readonly"
  }
}
---

# Current Board Hardware: m5stack_sticks3

Read this skill before operating hardware, assigning GPIOs, or writing Lua and board-specific code. **You cannot speculate or fabricate hardware information.**

## Rules
- Before operating any hardware, read this skill first.
- Before assigning a GPIO, check whether it is already occupied below.
- When writing Lua or board-specific code, use the listed device names instead of guessing hardware wiring.

## Board Summary
- Board: `m5stack_sticks3`
- Chip: `esp32s3`
- Version: `1`
- Manufacturer: `unknown`

## Device Inventory

The following devices are known to be present on this board:

### sticks3_power_manager
- Occupied IO:
  - `sda` -> `GPIO47`
  - `scl` -> `GPIO48`

### audio_dac
- Occupied IO:
  - `mclk` -> `GPIO18`
  - `bclk` -> `GPIO17`
  - `ws` -> `GPIO15`
  - `dout` -> `GPIO14`
  - `din` -> `GPIO16`
  - `sda` -> `GPIO47`
  - `scl` -> `GPIO48`

### audio_adc
- Occupied IO:
  - `mclk` -> `GPIO18`
  - `bclk` -> `GPIO17`
  - `ws` -> `GPIO15`
  - `dout` -> `GPIO14`
  - `din` -> `GPIO16`
  - `sda` -> `GPIO47`
  - `scl` -> `GPIO48`

### display_lcd
- Occupied IO:
  - `reset` -> `GPIO21`
  - `cs` -> `GPIO41`
  - `dc` -> `GPIO45`
  - `mosi` -> `GPIO39`
  - `sclk` -> `GPIO40`

## Notes
- If a device has no explicit IO mapping here, treat it as unknown instead of guessing.
