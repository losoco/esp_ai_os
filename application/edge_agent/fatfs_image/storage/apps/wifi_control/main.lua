-- WiFi Control App - status dashboard with touch controls

local display = require("display")
local board_manager = require("board_manager")
local delay = require("delay")
local system = require("system")
local lcd_touch = require("lcd_touch")

local W, H = 720, 720
local RUNNING = true
local touch_handle
local toast = nil
local toast_until = 0
local last_refresh_ms = 0
local wifi = {}

local BG = "#071018"
local CARD = "#0d1a27"
local CARD2 = "#101f30"
local TEXT = "#f4f7ff"
local MUTED = "#6f839a"
local GREEN = "#22c55e"
local YELLOW = "#ffaa22"
local RED = "#ef4444"
local BLUE = "#38bdf8"
local LINE = "#20364d"

local buttons = {
    refresh = {x=48, y=540, w=184, h=72, label="Refresh"},
    reconnect = {x=268, y=540, w=184, h=72, label="Reconnect"},
    toggle = {x=488, y=540, w=184, h=72, label="WiFi On/Off"},
}

local function now_ms()
    local ok, v = pcall(system.millis)
    return ok and v or 0
end

local function set_toast(msg, ms)
    toast = msg
    toast_until = now_ms() + (ms or 1600)
end

local function safe_info()
    local info = {}
    local ok, r = pcall(system.info)
    if ok and type(r) == "table" then info = r end
    local ok2, ip = pcall(system.ip)
    if ok2 then info.ip = ip end
    return info
end

local function refresh_wifi()
    local info = safe_info()
    wifi.ip = info.ip
    wifi.ssid = info.wifi_ssid
    wifi.rssi = info.wifi_rssi
    wifi.uptime_s = info.uptime_s or 0
    wifi.sram_free = info.sram_free
    wifi.psram_free = info.psram_free
    wifi.connected = (wifi.ip ~= nil and wifi.ip ~= "")
    last_refresh_ms = now_ms()
end

local function rssi_quality(rssi)
    if not rssi then return 0, "--", MUTED end
    if rssi >= -55 then return 100, "Excellent", GREEN end
    if rssi >= -67 then return 75, "Good", GREEN end
    if rssi >= -75 then return 50, "Fair", YELLOW end
    return 25, "Weak", RED
end

local function hit(btn, x, y)
    return x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h
end

local function handle_touch()
    if not touch_handle then return end
    local t = lcd_touch.poll(touch_handle)
    if t.just_released then
        if t.held_ms and t.held_ms > 1000 then
            RUNNING = false
            return
        end
        local x, y = t.x or -1, t.y or -1
        if hit(buttons.refresh, x, y) then
            refresh_wifi()
            set_toast("Status refreshed")
        elseif hit(buttons.reconnect, x, y) then
            set_toast("Reconnect API not available")
        elseif hit(buttons.toggle, x, y) then
            set_toast("WiFi control API not available")
        end
    end
end

local function draw_button(b, color)
    display.fill_round_rect(b.x, b.y, b.w, b.h, 16, "#13283b")
    display.draw_round_rect(b.x, b.y, b.w, b.h, 16, color or LINE)
    display.draw_text_aligned(b.x, b.y + 22, b.w, 28, b.label, {font_size=18, color=TEXT, align="center"})
end

local function draw()
    local connected = wifi.connected
    local status = connected and "CONNECTED" or "DISCONNECTED"
    local status_color = connected and GREEN or RED
    local q, qlabel, qcolor = rssi_quality(wifi.rssi)

    display.begin_frame({clear=true, color=BG})

    -- Header
    display.fill_round_rect(24, 20, W-48, 86, 22, CARD)
    display.draw_text_aligned(0, 34, W, 34, "WIFI CONTROL", {font_size=30, color=TEXT, align="center"})
    display.draw_text_aligned(0, 72, W, 20, status, {font_size=16, color=status_color, align="center"})

    -- Status card
    display.fill_round_rect(36, 130, W-72, 160, 18, CARD)
    display.draw_text_aligned(60, 150, W-120, 24, "NETWORK", {font_size=16, color=MUTED, align="left"})
    display.draw_text_aligned(60, 182, W-120, 34, wifi.ssid or "No SSID", {font_size=28, color=TEXT, align="left"})
    display.draw_text_aligned(60, 225, W-120, 24, "IP", {font_size=16, color=MUTED, align="left"})
    display.draw_text_aligned(60, 252, W-120, 24, wifi.ip or "No IP assigned", {font_size=20, color=connected and BLUE or MUTED, align="left"})

    -- Signal card
    display.fill_round_rect(36, 314, W-72, 150, 18, CARD)
    display.draw_text_aligned(60, 334, 220, 24, "SIGNAL", {font_size=16, color=MUTED, align="left"})
    display.draw_text_aligned(W-260, 334, 200, 24, wifi.rssi and string.format("%d dBm", wifi.rssi) or "-- dBm", {font_size=18, color=qcolor, align="right"})
    display.draw_rect(60, 378, W-120, 28, LINE)
    if q > 0 then
        display.fill_rect(63, 381, ((W-126) * q) // 100, 22, qcolor)
    end
    display.draw_text_aligned(60, 420, W-120, 26, qlabel, {font_size=22, color=qcolor, align="center"})

    -- System info
    display.fill_round_rect(36, 480, W-72, 42, 14, CARD2)
    local age = math.max(0, (now_ms() - last_refresh_ms) // 1000)
    local mem = wifi.sram_free and string.format("SRAM %.0f KB", wifi.sram_free / 1024) or "SRAM --"
    display.draw_text_aligned(52, 492, W-104, 18, string.format("Updated %ds ago   %s", age, mem), {font_size=13, color=MUTED, align="center"})

    draw_button(buttons.refresh, BLUE)
    draw_button(buttons.reconnect, YELLOW)
    draw_button(buttons.toggle, RED)

    display.draw_text_aligned(0, H-36, W, 18, "Tap buttons  |  Long press to exit", {font_size=13, color="#44576b", align="center"})

    if toast and now_ms() < toast_until then
        display.fill_round_rect(110, 632, W-220, 46, 18, "#18293a")
        display.draw_text_aligned(120, 644, W-240, 20, toast, {font_size=16, color=TEXT, align="center"})
    end

    display.present()
    display.end_frame()
end

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[wifi_control] No display") end
    W, H = lw or 720, lh or 720
    display.init(panel, io, W, H, pif)
    display.backlight(true)
    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")
    if touch_handle then lcd_touch.sync(touch_handle) end
    refresh_wifi()
end

local function run()
    init()
    print("[wifi_control] Running")
    while RUNNING do
        handle_touch()
        if now_ms() - last_refresh_ms > 5000 then refresh_wifi() end
        local ok, err = pcall(draw)
        if not ok then print("[wifi_control] draw error: " .. tostring(err)); break end
        delay.delay_ms(80)
    end
    display.clear(BG)
    display.draw_text_aligned(0, 0, W, H, "WiFi Control Closed", {font_size=32, color=MUTED, align="center"})
    display.present()
    delay.delay_ms(300)
    display.deinit()
    print("[wifi_control] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[wifi_control] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
end
