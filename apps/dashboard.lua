-- dashboard.lua - Device info dashboard
-- Shows battery, acceleration, heading, time on one screen
local display = require("display")
local board_manager = require("board_manager")
local lib_fuel_gauge = require("lib_fuel_gauge")
local lib_sc7a20h = require("lib_sc7a20h")
local magnetometer = require("magnetometer")
local i2c = require("i2c")
local delay = require("delay")
local math = math

-- Lua 5.1 compatible atan2
local function atan2(y, x)
    if x > 0 then return math.atan(y / x)
    elseif x < 0 and y >= 0 then return math.atan(y / x) + math.pi
    elseif x < 0 and y < 0 then return math.atan(y / x) - math.pi
    elseif x == 0 and y > 0 then return math.pi / 2
    elseif x == 0 and y < 0 then return -math.pi / 2
    else return 0
    end
end

local W, H = 720, 720
local RUNNING = true

-- Colors (display module accepts hex strings or named colors)
local RED    = "red"
local GREEN  = "green"
local WHITE  = "white"
local YELLOW = "yellow"
local BLUE   = "blue"
local GRAY   = "#808080"
local DARK   = "#202020"
local CYAN   = "cyan"
local ORANGE = "#ff8c00"
local SEPBG  = "#1a1a2e"

local fg, accel, mag_dev, touch_handle
local i2c_bus

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[dash] No display device found") end
    W, H = lw or 720, lh or 720
    display.init(panel, io, W, H, pif)
    display.backlight(true)

    i2c_bus = i2c.wrap(1)
    fg = lib_fuel_gauge.new({ bus = i2c_bus, chip = "bq27220" })
    accel = lib_sc7a20h.new({ bus = i2c_bus })
    mag_dev = magnetometer.new()

    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")
end

local function battery_color(soc)
    if soc > 50 then return GREEN
    elseif soc > 20 then return YELLOW
    else return RED
    end
end

local function draw_dashboard()
    local bat = fg:read()
    local ax, ay, az = accel:read_g()
    local mag_data = mag_dev:read()
    local heading = 0
    if mag_data and mag_data.magnetic then
        heading = math.deg(atan2(mag_data.magnetic.y, mag_data.magnetic.x)) % 360
    end
    local total_accel = math.sqrt(ax * ax + ay * ay + az * az)

    display.begin_frame({clear = true, color = DARK})

    -- Title bar
    display.fill_rect(0, 0, W, 60, SEPBG)
    display.draw_text_aligned(0, 10, W, 40, "ESP-Claw Dashboard", {font_size = 28, color = CYAN})

    local y = 80

    -- Battery section
    display.draw_text(30, y, "Battery", {font_size = 22, color = GRAY})
    y = y + 35

    local bar_x, bar_y, bar_w, bar_h = 30, y, W - 60, 30
    display.draw_round_rect(bar_x, bar_y, bar_w, bar_h, 8, GRAY)
    local fill_w = math.floor((bar_w - 6) * bat.soc / 100)
    if fill_w > 0 then
        display.fill_round_rect(bar_x + 3, bar_y + 3, fill_w, bar_h - 6, 6, battery_color(bat.soc))
    end
    display.draw_text_aligned(bar_x, bar_y + bar_h + 5, bar_w, 25,
        string.format("%d%%  %dmV  %dmA", bat.soc, bat.voltage_mv, bat.current_ma or 0),
        {font_size = 20, color = WHITE})
    y = y + bar_h + 40

    -- Separator
    display.draw_line(30, y, W - 30, y, SEPBG)
    y = y + 15

    -- Accelerometer section
    display.draw_text(30, y, "Accelerometer", {font_size = 22, color = GRAY})
    y = y + 35

    local labels = {"X", "Y", "Z"}
    local values = {ax, ay, az}
    local colors = {RED, GREEN, BLUE}
    for i = 1, 3 do
        display.draw_text(30, y, labels[i], {font_size = 20, color = colors[i]})
        local bar_cx = 30 + 200 + (W - 60 - 200) // 2
        local bar_half = (W - 60 - 200) // 2 - 20
        display.draw_line(30 + 200, y + 12, W - 30, y + 12, SEPBG)
        display.draw_line(bar_cx, y + 5, bar_cx, y + 19, GRAY)
        local v = math.max(-2, math.min(2, values[i]))
        local bx = math.floor(bar_cx + v / 2 * bar_half)
        display.fill_circle(bx, y + 12, 8, colors[i])
        display.draw_text(W - 120, y, string.format("%.2fg", values[i]), {font_size = 18, color = WHITE})
        y = y + 32
    end
    display.draw_text(30, y, string.format("Total: %.2fg", total_accel), {font_size = 18, color = YELLOW})
    y = y + 30

    -- Separator
    display.draw_line(30, y, W - 30, y, SEPBG)
    y = y + 15

    -- Compass section
    display.draw_text(30, y, "Heading", {font_size = 22, color = GRAY})
    y = y + 35

    local ccx, ccy, cr = W // 2, y + 80, 70
    display.draw_circle(ccx, ccy, cr, GRAY)
    display.draw_text_aligned(ccx - 15, ccy - cr - 5, 30, 20, "N", {font_size = 16, color = RED})
    display.draw_text_aligned(ccx - 15, ccy + cr - 15, 30, 20, "S", {font_size = 16, color = GRAY})
    local rad = math.rad(heading - 90)
    local nx = math.floor(ccx + math.cos(rad) * (cr - 10))
    local ny = math.floor(ccy + math.sin(rad) * (cr - 10))
    display.draw_line(ccx, ccy, nx, ny, RED)
    display.fill_circle(ccx, ccy, 5, WHITE)

    local dir = "N"
    local h = heading
    if h < 22.5 or h >= 337.5 then dir = "N"
    elseif h < 67.5 then dir = "NE"
    elseif h < 112.5 then dir = "E"
    elseif h < 157.5 then dir = "SE"
    elseif h < 202.5 then dir = "S"
    elseif h < 247.5 then dir = "SW"
    elseif h < 292.5 then dir = "W"
    else dir = "NW"
    end
    display.draw_text_aligned(ccx + cr + 20, ccy - 15, 150, 30,
        string.format("%.0f  %s", h, dir), {font_size = 24, color = YELLOW})

    display.draw_text_aligned(0, H - 35, W, 25, "Touch to exit", {font_size = 18, color = "#2a2a3e"})

    display.present()
    display.end_frame()
end

local function run()
    init()
    print("[dash] Running... touch to exit")

    while RUNNING do
        draw_dashboard()

        if touch_handle then
            local lcd_touch = require("lcd_touch")
            local t = lcd_touch.poll(touch_handle)
            if t.just_pressed then
                RUNNING = false
            end
        end

        delay.delay_ms(100)
    end

    display.clear(DARK)
    display.draw_text_aligned(0, 0, W, H, "Bye!", {font_size = 48, color = GRAY})
    display.present()
    delay.delay_ms(500)
    display.backlight(false)
    display.deinit()
    if fg then fg:close() end
    if accel then accel:close() end
    if mag_dev then mag_dev:close() end
    print("[dash] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[dash] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
    pcall(function() if fg then fg:close() end end)
    pcall(function() if accel then accel:close() end end)
    pcall(function() if mag_dev then mag_dev:close() end end)
end
