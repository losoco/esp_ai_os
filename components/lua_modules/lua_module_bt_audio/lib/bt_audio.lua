-- bt_audio.lua
-- Bluetooth audio module mode switching for boards with a BT audio chip
-- connected via UART (AT commands) and I2S.
--
-- The BT chip is the I2S clock master (provides BCLK/WS). It must be in
-- Mode 1 for the ESP32-P4 to output local audio through the I2S slave
-- interface.
--
-- Modes:
--   Mode 1: Local voice interaction (ESP32 -> I2S -> BT chip -> speaker)
--   Mode 2: BT pairing (connect to BT headphones/speakers)
--   Mode 3: Music receive (phone -> device as BT speaker)

local uart = require("uart")
local delay = require("delay")

local M = {}

-- Default UART config (MetalioClaw4: UART2, TX=26, RX=27, 115200)
local DEFAULT_PORT = 2
local DEFAULT_TX   = 26
local DEFAULT_RX   = 27
local DEFAULT_BAUD = 115200

-- Delay between the two AT commands in a mode-switch sequence (ms)
local CMD_GAP = 700
-- Delay after the last command before releasing UART (ms)
local SETTLE  = 200

--- Send a pair of AT commands with the mandatory gap, then close UART.
--- @param cmd1 string First AT command (without \r\n)
--- @param cmd2 string Second AT command (without \r\n)
--- @param opts table|nil Optional UART config override: {port, tx, rx, baud}
--- @return boolean ok
--- @return string|nil err
local function send_at_pair(cmd1, cmd2, opts)
    opts = opts or {}
    local port = opts.port or DEFAULT_PORT
    local tx   = opts.tx   or DEFAULT_TX
    local rx   = opts.rx   or DEFAULT_RX
    local baud = opts.baud or DEFAULT_BAUD

    local ok, u = pcall(uart.new, port, tx, rx, baud)
    if not ok then
        return false, "uart.new failed: " .. tostring(u)
    end

    local function cleanup()
        pcall(u.close, u)
    end

    local c1 = cmd1 .. "\r\n"
    local ok2, err = pcall(u.write, u, c1)
    if not ok2 then
        cleanup()
        return false, "write " .. cmd1 .. " failed: " .. tostring(err)
    end

    delay.delay_ms(CMD_GAP)

    local c2 = cmd2 .. "\r\n"
    ok2, err = pcall(u.write, u, c2)
    if not ok2 then
        cleanup()
        return false, "write " .. cmd2 .. " failed: " .. tostring(err)
    end

    delay.delay_ms(SETTLE)
    cleanup()
    return true
end

--- Switch to Mode 1 (local playback / voice interaction).
--- @param opts table|nil Optional UART config override
--- @return boolean ok
--- @return string|nil err
function M.set_local_mode(opts)
    return send_at_pair("AT+RX=2", "AT+MODE=1", opts)
end

--- Switch to Mode 2 (BT pairing - connect to headphones/speakers).
--- @param opts table|nil Optional UART config override
--- @return boolean ok
--- @return string|nil err
function M.set_pair_mode(opts)
    return send_at_pair("AT+TX=1", "AT+MODE=2", opts)
end

--- Switch to Mode 3 (music receive - phone plays through device).
--- @param opts table|nil Optional UART config override
--- @return boolean ok
--- @return string|nil err
function M.set_music_mode(opts)
    return send_at_pair("AT+RX=1", "AT+MODE=3", opts)
end

--- Ensure Mode 1 is active. Safe to call before any local audio playback.
--- @param opts table|nil Optional UART config override
--- @return boolean ok
--- @return string|nil err
function M.ensure_local(opts)
    return M.set_local_mode(opts)
end

--- Switch to a mode by name.
--- @param mode string "local" | "pair" | "music"
--- @param opts table|nil Optional UART config override
--- @return boolean ok
--- @return string|nil err
function M.set_mode(mode, opts)
    if mode == "local" then
        return M.set_local_mode(opts)
    elseif mode == "pair" then
        return M.set_pair_mode(opts)
    elseif mode == "music" then
        return M.set_music_mode(opts)
    else
        return false, "unknown mode: " .. tostring(mode)
    end
end

return M
