-- BT Audio Mode UI
-- Touch buttons to switch Bluetooth audio chip mode.
-- Modes:
--   local: ESP32 local playback through speaker
--   pair : Bluetooth pairing/scanning mode
--   music: phone streams music to this device
-- Long press anywhere to exit.

local display = require("display")
local board_manager = require("board_manager")
local lcd_touch = require("lcd_touch")
local delay = require("delay")
local bt_audio = require("bt_audio")

local W, H = 720, 720
local RUNNING = true
local touch_handle

local BG = "#101820"
local PANEL = "#1f2d3a"
local CARD = "#263847"
local CARD_ACTIVE = "#2ecc71"
local CARD_PRESS = "#3d5568"
local TEXT = "#f5f7fa"
local MUTED = "#aeb9c4"
local OK = "#2ecc71"
local WARN = "#f4d35e"
local ERR = "#ff5252"
local BORDER = "#5d7282"

local current_mode = "unknown"
local switching = false
local status = "Select a mode"
local status_color = MUTED
local pressed_id = nil
local last_touch_down_ms = nil

local buttons = {
    {
        id = "local",
        title = "LOCAL",
        subtitle = "ESP32 plays local audio",
        hint = "Use before Canon.mp3 / TTS",
    },
    {
        id = "pair",
        title = "PAIR",
        subtitle = "Pair BT headphones/speaker",
        hint = "Scan and connect BT audio device",
    },
    {
        id = "music",
        title = "MUSIC",
        subtitle = "Phone streams to this device",
        hint = "Use as Bluetooth speaker",
    },
}

local function set_status(text, color)
    status = text or ""
    status_color = color or MUTED
    print("[bt_audio_mode] " .. status)
end

local function button_rect(i)
    local margin = 48
    local gap = 22
    local bh = 130
    local bw = W - margin * 2
    local top = 185
    local x = margin
    local y = top + (i - 1) * (bh + gap)
    return x, y, bw, bh
end

local function hit_button(x, y)
    for i, b in ipairs(buttons) do
        local bx, by, bw, bh = button_rect(i)
        if x >= bx and x <= bx + bw and y >= by and y <= by + bh then
            return b.id
        end
    end
    return nil
end

local function switch_mode(mode)
    if switching then return end
    switching = true
    current_mode = mode
    set_status("Switching to " .. mode .. " ...", WARN)
    display.begin_frame({clear = true, color = BG})
    display.draw_text_aligned(0, 0, W, H, "Switching to " .. mode .. " ...", {font_size = 34, color = WARN})
    display.present()
    display.end_frame()

    local ok, err = bt_audio.set_mode(mode)
    if ok then
        current_mode = mode
        set_status("OK: " .. mode .. " mode active", OK)
    else
        set_status("ERROR: " .. tostring(err), ERR)
    end
    switching = false
end

local function handle_touch()
    if not touch_handle then return end
    local t = lcd_touch.poll(touch_handle)
    if not t then return end

    if t.pressed and t.held_ms and t.held_ms > 1500 then
        RUNNING = false
        return
    end

    if t.just_pressed then
        pressed_id = hit_button(t.x, t.y)
    end

    if t.just_released then
        local released_id = hit_button(t.x, t.y)
        if pressed_id and released_id == pressed_id then
            switch_mode(pressed_id)
        end
        pressed_id = nil
    end
end

local function draw_header()
    display.fill_rect(0, 0, W, 146, PANEL)
    display.draw_text(34, 26, "BT AUDIO MODE", {font_size = 34, color = TEXT})
    display.draw_text(36, 76, "Tap a mode. Long press to exit.", {font_size = 20, color = MUTED})

    local mode_text = "Current: " .. tostring(current_mode)
    local tw = display.measure_text(mode_text, {font_size = 22})
    display.fill_round_rect(W - tw - 58, 34, tw + 28, 38, 18, "#14212b")
    display.draw_text(W - tw - 44, 41, mode_text, {font_size = 22, color = current_mode == "unknown" and MUTED or OK})
end

local function draw_button(i, b)
    local x, y, bw, bh = button_rect(i)
    local active = current_mode == b.id
    local pressed = pressed_id == b.id
    local fill = active and CARD_ACTIVE or (pressed and CARD_PRESS or CARD)
    local text_color = active and "#06120a" or TEXT
    local sub_color = active and "#0b2a14" or MUTED

    display.fill_round_rect(x, y, bw, bh, 18, fill)
    display.draw_round_rect(x, y, bw, bh, 18, active and OK or BORDER)

    display.draw_text(x + 28, y + 22, b.title, {font_size = 32, color = text_color})
    display.draw_text(x + 28, y + 66, b.subtitle, {font_size = 21, color = sub_color})
    display.draw_text(x + 28, y + 96, b.hint, {font_size = 17, color = sub_color})

    if active then
        display.draw_text_aligned(x + bw - 120, y + 38, 86, 48, "ON", {font_size = 28, color = "#06120a"})
    end
end

local function draw_footer()
    display.fill_rect(0, H - 76, W, 76, "#0b1117")
    display.draw_text(34, H - 54, status, {font_size = 21, color = status_color})
end

local function draw()
    display.begin_frame({clear = true, color = BG})
    draw_header()
    for i, b in ipairs(buttons) do
        draw_button(i, b)
    end
    draw_footer()
    display.present()
    display.end_frame()
end

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[bt_audio_mode] No display device found") end
    W, H = lw or 720, lh or 720
    display.init(panel, io, W, H, pif)
    display.backlight(true)

    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")
    if touch_handle then
        pcall(lcd_touch.sync, touch_handle)
    else
        set_status("No touch device found", ERR)
    end
end

local function shutdown()
    display.clear(BG)
    display.draw_text_aligned(0, 0, W, H, "Bye", {font_size = 48, color = MUTED})
    display.present()
    delay.delay_ms(250)
    display.backlight(false)
    display.deinit()
end

local function run()
    init()
    print("[bt_audio_mode] Running. Tap local/pair/music, long press to exit.")
    while RUNNING do
        handle_touch()
        draw()
        delay.delay_ms(30)
    end
    shutdown()
    print("[bt_audio_mode] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[bt_audio_mode] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
end
