-- BT audio mode switch script for Agent calls.
--
-- Usage:
--   lua --run --path {CUR_SKILL_DIR}/scripts/switch_mode.lua --args-json {"mode":"local"}
--
-- Modes: "local" (default), "pair", "music"

local bt_audio = require("bt_audio")

local mode = "local"

-- Parse args from global args table (set by cap_lua runtime)
if type(args) == "table" and args.mode then
    mode = tostring(args.mode)
end

print("[bt_audio] switching to mode: " .. mode)

local ok, err = bt_audio.set_mode(mode)
if not ok then
    print("[bt_audio] ERROR: " .. tostring(err))
    error(err)
end

print("[bt_audio] OK: switched to " .. mode .. " mode")
