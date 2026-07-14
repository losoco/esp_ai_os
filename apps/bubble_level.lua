-- bubble_level.lua - Spirit level using accelerometer + display
-- Shows a bubble level that responds to device tilt
local display = require("display")
local board_manager = require("board_manager")
local lib_sc7a20h = require("lib_sc7a20h")
local delay = require("delay")
local i2c = require("i2c")
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
local CX, CY = W // 2, H // 2
local RUNNING = true

-- Colors (display module accepts hex strings or named colors)
local RED    = "red"
local GREEN  = "green"
local WHITE  = "white"
local YELLOW = "yellow"
local GRAY   = "#808080"
local DARK   = "#202020"
local CYAN   = "cyan"
local LIGHTBG = "#1a1a2e"

local accel
local touch_handle

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[level] No display device found") end
    W, H = lw or 720, lh or 720
    CX, CY = W // 2, H // 2
    display.init(panel, io, W, H, pif)
    display.backlight(true)

    local bus = i2c.wrap(1)
    accel = lib_sc7a20h.new({ bus = bus })

    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")
end

local function draw_level(ax, ay)
    display.begin_frame({clear = true, color = DARK})

    -- Tilt angles in degrees
    local tilt_x = math.deg(atan2(ax, 9.81 * 1000))
    local tilt_y = math.deg(atan2(ay, 9.81 * 1000))

    -- Map tilt to bubble offset (max ~120px for 30 deg)
    local max_tilt = 30
    local max_offset = 120
    local bx = math.floor(CX + math.max(-max_offset, math.min(max_offset, (tilt_y / max_tilt) * max_offset)))
    local by = math.floor(CY + math.max(-max_offset, math.min(max_offset, (-tilt_x / max_tilt) * max_offset)))

    -- Outer circle (vial)
    local vial_r = 200
    display.fill_circle(CX, CY, vial_r, LIGHTBG)
    display.draw_circle(CX, CY, vial_r, GRAY)

    -- Cross hairs
    display.draw_line(CX - vial_r, CY, CX + vial_r, CY, GRAY)
    display.draw_line(CX, CY - vial_r, CX, CY + vial_r, GRAY)

    -- Center target
    display.draw_circle(CX, CY, 30, GREEN)

    -- Concentric rings
    for r = 60, 180, 30 do
        display.draw_circle(CX, CY, r, "#2a2a3e")
    end

    -- Bubble
    local bubble_r = 35
    local is_level = math.abs(bx - CX) < 15 and math.abs(by - CY) < 15
    local bubble_color = is_level and GREEN or CYAN
    display.fill_circle(bx, by, bubble_r, bubble_color)
    display.draw_circle(bx, by, bubble_r, WHITE)
    display.fill_circle(bx - 10, by - 10, 12, WHITE)

    -- Status text
    local status = is_level and "LEVEL!" or "Tilt"
    local status_color = is_level and GREEN or YELLOW
    display.draw_text_aligned(0, 40, W, 40, status, {font_size = 32, color = status_color})

    display.draw_text_aligned(0, H - 80, W, 30,
        string.format("Pitch: %+.1f  Roll: %+.1f", tilt_x, tilt_y),
        {font_size = 22, color = GRAY})
    display.draw_text_aligned(0, H - 40, W, 30, "Touch to exit", {font_size = 18, color = "#2a2a3e"})

    display.present()
    display.end_frame()
end

local function run()
    init()
    print("[level] Running... touch to exit")

    while RUNNING do
        local ax, ay, az = accel:read_mg()
        draw_level(ax, ay)

        if touch_handle then
            local lcd_touch = require("lcd_touch")
            local t = lcd_touch.poll(touch_handle)
            if t.just_pressed then
                RUNNING = false
            end
        end

        delay.delay_ms(30)
    end

    display.clear(DARK)
    display.draw_text_aligned(0, 0, W, H, "Bye!", {font_size = 48, color = GRAY})
    display.present()
    delay.delay_ms(500)
    display.backlight(false)
    display.deinit()
    if accel then accel:close() end
    print("[level] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[level] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
    pcall(function() if accel then accel:close() end end)
end
